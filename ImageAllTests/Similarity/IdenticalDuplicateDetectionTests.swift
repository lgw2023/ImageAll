@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class IdenticalDuplicateDetectionTests: XCTestCase {
    func testStoryVideoFreezePreservesOriginalBytesAndCleansCancelledCopy() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let bytes = try Data(contentsOf: fixture)
        let item = try env.seedAsset(relativePath: "clip.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1000)
        let base = env.makeCompletionService()
        let service = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        let output = env.root.appendingPathComponent("frozen.mp4")
        let frozen = try service.freezeStoryVideo(assetID: item.assetID, expectedRevision: 1, destination: output)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(frozen.sha256, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(frozen.byteCount, Int64(bytes.count))
        XCTAssertEqual(frozen.durationMs, 1000)
        XCTAssertThrowsError(try service.freezeStoryVideo(assetID: item.assetID, expectedRevision: 1, destination: output))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        let cancelled = env.root.appendingPathComponent("cancelled.mp4")
        var calls = 0
        XCTAssertThrowsError(try service.freezeStoryVideo(assetID: item.assetID, expectedRevision: 1, destination: cancelled) {
            calls += 1
            if calls >= 3 { throw CancellationError() }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertThrowsError(try service.freezeStoryVideo(assetID: item.assetID, expectedRevision: 2, destination: cancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertEqual(try Data(contentsOf: item.fileURL), bytes)
    }

    func testPhotosMultiFrameUsesLocalResourceIdentityAndRejectsCloudOrChangedSource() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let local = env.sourceRoot.appendingPathComponent("photos-resource.mp4")
        try Data(contentsOf: fixture).write(to: local)
        let id = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let port = SyntheticVideoAnalysisSource(url: local)
        let base = env.makeCompletionService()
        let service = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess,
            clock: base.clock, photosSource: port)
        let cold = try service.analyzeWithFeatures(assetID: id, expectedRevision: 1)
        XCTAssertEqual(cold.sampling.frames.count, 3)
        let warm = try service.analyzeWithFeatures(assetID: id, expectedRevision: 1)
        XCTAssertTrue(warm.reusedFeatures)
        XCTAssertEqual(warm.sampling.attemptedFrameCount, 0)
        port.resourceIdentity = "changed-resource"
        let changed = try service.analyzeWithFeatures(assetID: id, expectedRevision: 1)
        XCTAssertFalse(changed.reusedFeatures)
        XCTAssertEqual(changed.sampling.attemptedFrameCount, 3)
        port.failure = PhotosLibraryError.cloudOnly
        XCTAssertThrowsError(try service.analyzeWithFeatures(assetID: id)) {
            XCTAssertEqual($0 as? PhotosLibraryError, .cloudOnly)
        }
        port.failure = nil
        XCTAssertThrowsError(try service.analyze(assetID: id, forceRebuild: true, onFrame: { _ in
            port.resourceIdentity = "changed-during-analysis"
        }))
        XCTAssertThrowsError(try service.analyzeWithFeatures(assetID: id, checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let recovered = try service.analyzeWithFeatures(assetID: id)
        XCTAssertFalse(recovered.reusedFeatures)
        XCTAssertEqual(recovered.sampling.attemptedFrameCount, 3)
        let loader = VideoMultiFrameFeatureLoader(analysis: service, cachesDirectory: env.root.appendingPathComponent("features"))
        XCTAssertEqual(try loader.loadOrGenerateSync(assetID: id).identity.preprocessingRevision, 2)
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = 2 WHERE id = ?", arguments: [id.uuidString.lowercased()])
        }
        XCTAssertThrowsError(try service.analyzeWithFeatures(assetID: id, expectedRevision: 1))
        XCTAssertEqual(try service.analyzeWithFeatures(assetID: id, expectedRevision: 2).sampling.attemptedFrameCount, 3)
    }

    func testContentCandidatesUseAnalyzedDurationScopeAndNeverCreateExactGroups() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let bytes = try Data(contentsOf: fixture)
        let baseItem = try env.seedAsset(relativePath: "base.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let copy = try env.seedAsset(relativePath: "candidate.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let missing = try env.seedAsset(relativePath: "missing.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let unseen = try env.seedAsset(relativePath: "unseen.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let base = env.makeCompletionService()
        let service = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        for id in [baseItem.assetID, copy.assetID, missing.assetID] { _ = try service.analyzeWithFeatures(assetID: id) }
        try FileManager.default.removeItem(at: env.sourceRoot.appendingPathComponent("missing.mp4"))
        let result = try service.contentCandidates(assetID: baseItem.assetID, expectedRevision: 1)
        XCTAssertEqual(result.items.map(\.id), [copy.assetID])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.items.first?.score ?? 0, 1, accuracy: 0.0001)
        XCTAssertFalse(result.items.contains(where: { $0.id == unseen.assetID }))
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [baseItem.assetID, copy.assetID], mediaKind: .video)
        XCTAssertTrue(clusters.isEmpty, "Content evidence must not become byte-identical authority")
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET duration_ms = 9000 WHERE id = ?",
                arguments: [copy.assetID.uuidString.lowercased()])
        }
        XCTAssertTrue(try service.contentCandidates(assetID: baseItem.assetID, expectedRevision: 1).items.isEmpty)
        XCTAssertThrowsError(try service.contentCandidates(assetID: baseItem.assetID, expectedRevision: 1,
            checkCancellation: { throw CancellationError() }))
    }

    func testRealVideoFeaturesTrainPredictAndResolveFrozenReviewEvidence() async throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let positiveURL = env.root.appendingPathComponent("positive.mov")
        let negativeURL = env.root.appendingPathComponent("negative.mov")
        try await Self.writeVideoControl(positiveURL, variant: 3)
        try await Self.writeVideoControl(negativeURL, variant: 2)
        let positive = try Data(contentsOf: positiveURL)
        let negative = try Data(contentsOf: negativeURL)
        var assets: [UUID] = []
        for index in 0..<5 {
            assets.append(try env.seedAsset(relativePath: "training-\(index).mov",
                contents: index == 2 || index == 3 ? negative : positive,
                mediaType: "com.apple.quicktime-movie", mediaKind: .video, durationMs: 4000).assetID)
        }
        let tagID = UUID()
        try await env.database.pool.write { db in
            try db.execute(sql: "INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms) VALUES (?, 'Circle', 'circle', 'active', 1, 1)",
                arguments: [tagID.uuidString.lowercased()])
        }
        let tags = GRDBTagCatalogRepository(database: env.database)
        _ = try tags.batchAccept(tagID: tagID, assetIDs: Array(assets[0...1]), timestampMs: 2)
        _ = try tags.batchReject(tagID: tagID, assetIDs: Array(assets[2...3]), timestampMs: 2)
        let base = env.makeCompletionService()
        let analysis = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        let loader = VideoMultiFrameFeatureLoader(analysis: analysis, cachesDirectory: env.root.appendingPathComponent("features"))
        let service = PersonalizedSuggestionService(database: env.database, featureLoader: loader)
        let result = try await service.generateSuggestions(tagID: tagID, candidateAssetIDs: [assets[4]],
            mediaKind: .video, representation: .videoMultiFrame)
        XCTAssertEqual(result.predictedCandidateCount, 1)
        let reader = VideoPredictionEvidenceReader(database: env.database)
        let snapshot = try XCTUnwrap(reader.read(assetID: assets[4], revision: 1, tagID: tagID))
        XCTAssertEqual(snapshot.frames.count, 5)
        XCTAssertTrue(snapshot.frames.allSatisfy { $0.jpegBytes != nil })
        let actual = try analysis.analyzeWithFeatures(assetID: assets[4], expectedRevision: 1)
        XCTAssertTrue(actual.reusedFeatures)
        XCTAssertEqual(actual.sampling.attemptedFrameCount, 0)
        XCTAssertEqual(snapshot.frames.map(\.actualTimeMs), actual.sampling.frames.map(\.actualTimeMs))
        XCTAssertEqual(snapshot.frames.compactMap(\.jpegBytes), actual.sampling.frames.map(\.jpegBytes))
        let counts = try await env.database.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model_sample WHERE preprocessing_revision = 2"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model WHERE media_kind = 'image'"))
        }
        XCTAssertEqual(counts.0, 4)
        XCTAssertEqual(counts.1, 0)
        // Re-run through the production enqueue/worker boundary with cold frame caches.
        try await env.database.pool.write { db in
            try db.execute(sql: "DELETE FROM video_analysis_frame")
            try db.execute(sql: "DELETE FROM video_analysis_feature")
        }
        let now = FolderReconcileTestSupport.baseTimeMs + 100_000
        let queue = JobTestSupport.makeQueue(database: env.database, nowMs: now, retryDelayMs: 0)
        let handler = FullLibrarySuggestionsHandler(dependencies: .init(database: env.database, queue: queue,
            featureLoader: loader, clock: FixedJobClock(nowMs: now), multiFrameFeatureLoader: loader))
        let coordinator = JobExecutionCoordinator(queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue))
        let review = PersonalizationReviewService(database: env.database, queue: queue,
            executionCoordinator: coordinator, tags: tags, clock: FixedJobClock(nowMs: now))
        let jobID = try review.enqueueFullLibrarySuggestions(mediaKind: .video, tagID: tagID,
            mode: .generate, sourceIDs: [env.sourceID], representation: .videoMultiFrame)
        let payload = try FullLibrarySuggestionsCodec.decodePayload(queue.fetchJob(id: jobID).payload)
        XCTAssertEqual(payload.representation, .videoMultiFrame)
        XCTAssertEqual(payload.frozenPositiveSamples.count, 2)
        XCTAssertEqual(payload.frozenNegativeSamples.count, 2)
        _ = try coordinator.claimAndExecuteOnce(.init(owner: "synthetic-video-worker", leaseDurationMs: 60_000,
            allowedKinds: [FullLibrarySuggestionsJobFactory.kind]))
        XCTAssertEqual(try queue.fetchJob(id: jobID).state, .completed)
        let queued = try XCTUnwrap(reader.read(assetID: assets[4], revision: 1, tagID: tagID))
        XCTAssertGreaterThan(queued.modelRevision, snapshot.modelRevision)
        XCTAssertEqual(queued.frames.count, 5)
        XCTAssertTrue(queued.frames.allSatisfy { $0.jpegBytes != nil })
        let page = try review.fetchReviewQueue(mediaKind: .video, tagID: tagID,
            sourceIDs: [env.sourceID], cursor: nil, limit: 10)
        XCTAssertEqual(page.items.map(\.assetID), [assets[4]])
        XCTAssertNotNil(try GRDBTrainingRunRepository(database: env.database).fetch(jobID: jobID))
        _ = try tags.batchAccept(tagID: tagID, assetIDs: [assets[4]], timestampMs: 3)
        XCTAssertNil(try reader.read(assetID: assets[4], revision: 1, tagID: tagID))
    }

    func testVideoFeatureEvidencePersistsAndRebuildsDamagedOrStaleResults() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let item = try env.seedAsset(relativePath: "features.mp4", contents: Data(contentsOf: fixture),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let base = env.makeCompletionService()
        let service = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        let cold = try service.analyzeWithFeatures(assetID: item.assetID)
        XCTAssertFalse(cold.reusedFeatures)
        let loader = VideoMultiFrameFeatureLoader(analysis: service,
            cachesDirectory: env.root.appendingPathComponent("feature-cache", isDirectory: true))
        let payload = try loader.loadOrGenerateSync(assetID: item.assetID)
        XCTAssertEqual(payload.identity.preprocessingRevision, 2)
        XCTAssertEqual(payload.elementCount, cold.features.aggregate.count)
        let evidence = try XCTUnwrap(payload.videoEvidence)
        XCTAssertEqual(evidence.vectorSHA256, payload.vectorSHA256)
        XCTAssertEqual(evidence.frames.map(\.actualTimeMs), cold.sampling.frames.map(\.actualTimeMs))
        XCTAssertEqual(evidence.frames.map(\.jpegSHA256), cold.sampling.frames.map { Data(SHA256.hash(data: $0.jpegBytes)) })
        XCTAssertEqual(try PersonalizedSuggestionScoringCore.decode(payload), cold.features.aggregate)
        XCTAssertNotNil(try GRDBPersonalizationRepository(database: env.database).featureRegistration(identity: payload.identity))
        let reopened = try CatalogDatabase.open(at: env.root.appendingPathComponent("catalog.sqlite"))
        let restarted = FolderVideoAnalysisService(database: reopened, sourceAccess: base.sourceAccess, clock: base.clock)
        let warm = try restarted.analyzeWithFeatures(assetID: item.assetID)
        XCTAssertTrue(warm.reusedFeatures)
        XCTAssertEqual(warm.sampling.attemptedFrameCount, 0)
        XCTAssertEqual(warm.features.aggregate, cold.features.aggregate)
        XCTAssertEqual(warm.features.frames.map(\.timeMs), cold.features.frames.map(\.timeMs))
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE video_analysis_feature SET payload = ?", arguments: [Data("broken".utf8)])
        }
        let repaired = try service.analyzeWithFeatures(assetID: item.assetID)
        XCTAssertFalse(repaired.reusedFeatures)
        XCTAssertEqual(repaired.sampling.attemptedFrameCount, 0)
        let forced = try service.analyzeWithFeatures(assetID: item.assetID, forceRebuild: true)
        XCTAssertFalse(forced.reusedFeatures)
        XCTAssertEqual(forced.sampling.attemptedFrameCount, 3)
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?",
                arguments: [item.assetID.uuidString.lowercased()])
        }
        let revised = try service.analyzeWithFeatures(assetID: item.assetID)
        XCTAssertFalse(revised.reusedFeatures)
        XCTAssertEqual(revised.sampling.attemptedFrameCount, 3)
        XCTAssertThrowsError(try service.analyzeWithFeatures(assetID: item.assetID, expectedRevision: 1))
    }

    func testLateTargetAndSharedCoverVideoControlsWithRealVision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VideoControls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let late = root.appendingPathComponent("late-circle.mov")
        let different = root.appendingPathComponent("same-cover-squares.mov")
        let target = root.appendingPathComponent("target-circle.mov")
        try await Self.writeVideoControl(late, variant: 1)
        try await Self.writeVideoControl(different, variant: 2)
        try await Self.writeVideoControl(target, variant: 3)
        let sampler = AVFoundationVideoAnalysisSampler()
        let sampling = try sampler.sample(sourceFileDescriptorURL: late, mediaType: "com.apple.quicktime-movie", durationMs: 4_000)
        let otherSampling = try sampler.sample(sourceFileDescriptorURL: different, mediaType: "com.apple.quicktime-movie", durationMs: 4_000)
        let targetSampling = try sampler.sample(sourceFileDescriptorURL: target, mediaType: "com.apple.quicktime-movie", durationMs: 4_000)
        let features = try VideoMultiFrameFeatureSet.generate(sampling)
        let other = try VideoMultiFrameFeatureSet.generate(otherSampling)
        let reference = try VideoMultiFrameFeatureSet.generate(targetSampling)
        let evidence = try features.contentMatch(to: reference)
        let coverScore = zip(features.frames[0].values, other.frames[0].values).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let candidateScore = try features.contentMatch(to: other).score
        let poster = try AVFoundationDerivedVideoPosterGenerator().makePosterBytes(
            sourceFileDescriptorURL: late, mediaType: "com.apple.quicktime-movie", durationMs: 4_000, maximumPixelSize: 512)
        // Use the same Vision generator directly for the existing single-poster input.
        let posterFeature = try VideoMultiFrameFeatureSet.singleImageUnitFeature(poster)
        let posterTargetScore = zip(posterFeature, reference.frames[0].values).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let hit = try XCTUnwrap(features.frames.first(where: { $0.timeMs == evidence.leftTimeMs }))
        let hitScore = zip(hit.values, reference.frames[0].values).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(sampling.frames.count, 5)
        XCTAssertGreaterThanOrEqual(evidence.leftTimeMs, 2_000)
        XCTAssertGreaterThan(hitScore, posterTargetScore + 0.05)
        XCTAssertGreaterThan(coverScore, 0.98)
        XCTAssertLessThan(candidateScore, coverScore - 0.05)
        let report: [String: Any] = ["fixtureOnly": true, "posterTargetCosine": posterTargetScore,
            "bestFrameTargetCosine": hitScore, "evidenceTimeMs": evidence.leftTimeMs,
            "sharedCoverCosine": coverScore, "multiFrameCoverageCosine": candidateScore,
            "decodedFrames": sampling.attemptedFrameCount, "jpegBytes": sampling.encodedByteCount,
            "samplingSeconds": sampling.elapsedSeconds, "actualTimesMs": sampling.frames.map(\.actualTimeMs),
            "representation": features.representationIdentity]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("VIDEO_CONTENT_CONTROL \(String(decoding: json, as: UTF8.self))")
        if let evidenceRoot = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let output = URL(fileURLWithPath: evidenceRoot)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try json.write(to: output.appendingPathComponent("content-control-measurements.json"))
            for url in [late, different, target] {
                try Data(contentsOf: url).write(to: output.appendingPathComponent(url.lastPathComponent))
            }
            for frame in sampling.frames {
                try frame.jpegBytes.write(to: output.appendingPathComponent("late-circle-\(frame.actualTimeMs)ms.jpg"))
            }
        }
    }

    private static func writeVideoControl(_ url: URL, variant: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 256, AVVideoHeightKey: 192])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 256, kCVPixelBufferHeightKey as String: 192])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<40 {
            try Task.checkCancellation()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                    writer.cancelWriting(); throw FeaturePrintError.generationFailed
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, 256, 192, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FeaturePrintError.generationFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let kind = variant == 3 ? 1 : (frame < 20 ? 0 : variant)
            for y in 0..<192 { for x in 0..<256 {
                let offset = y * stride + x * 4
                var red = 230, green = 230, blue = 230
                if kind == 0 {
                    let shade = (x / 16) % 2 == 0 ? 40 : 200
                    red = shade; green = shade; blue = shade
                } else if kind == 1, (x - 128) * (x - 128) + (y - 96) * (y - 96) < 65 * 65 {
                    red = 235; green = 25; blue = 30
                } else if kind == 2, (x / 32 + y / 32) % 2 == 0 {
                    red = 20; green = 40; blue = 230
                }
                pixels[offset] = UInt8(blue); pixels[offset + 1] = UInt8(green)
                pixels[offset + 2] = UInt8(red); pixels[offset + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? FeaturePrintError.generationFailed
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FeaturePrintError.generationFailed }
    }

    func testVideoMultiFrameFeaturesUseVisionAndRejectPosterModelIdentity() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let sample = try AVFoundationVideoAnalysisSampler().sample(sourceFileDescriptorURL: fixture,
            mediaType: "public.mpeg-4", durationMs: 1_000)
        let features = try VideoMultiFrameFeatureSet.generate(sample)
        XCTAssertEqual(features.frames.map(\.timeMs), sample.frames.map(\.actualTimeMs))
        XCTAssertFalse(features.aggregate.isEmpty)
        XCTAssertEqual(try features.modelInput(expectedRepresentation: VideoMultiFrameFeatureSet.identity), features.aggregate)
        XCTAssertThrowsError(try features.modelInput(expectedRepresentation: "videoPoster.v1"))
        XCTAssertEqual(try features.contentMatch(to: features).score, 1, accuracy: 0.0001)
        XCTAssertThrowsError(try VideoMultiFrameFeatureSet.generate(sample, checkCancellation: { throw CancellationError() }))
        // A common cover alone must not imply coverage of the remaining video.
        let left = VideoMultiFrameFeatureSet(representationIdentity: VideoMultiFrameFeatureSet.identity,
            frames: [.init(timeMs: 0, values: [1, 0, 0]), .init(timeMs: 500, values: [0, 1, 0])], aggregate: [0.7, 0.7, 0])
        let right = VideoMultiFrameFeatureSet(representationIdentity: VideoMultiFrameFeatureSet.identity,
            frames: [.init(timeMs: 0, values: [1, 0, 0]), .init(timeMs: 500, values: [0, 0, 1])], aggregate: [0.7, 0, 0.7])
        XCTAssertEqual(try left.contentMatch(to: right).score, 0.5, accuracy: 0.0001)
        print("VIDEO_VISION_FEATURES frames=\(features.frames.count) dimension=\(features.aggregate.count) identity=\(features.representationIdentity)")
    }

    func testFolderMultiframeCheckpointsResumeAndRejectRevisionOrSourceChanges() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let bytes = try Data(contentsOf: fixture)
        let item = try env.seedAsset(relativePath: "analysis.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        let base = env.makeCompletionService()
        let service = FolderVideoAnalysisService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        XCTAssertThrowsError(try service.analyze(assetID: item.assetID, onFrame: { _ in throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let resumed = try service.analyze(assetID: item.assetID)
        XCTAssertEqual(resumed.reusedFrameCount, 1)
        XCTAssertEqual(resumed.attemptedFrameCount, 2)
        XCTAssertEqual(resumed.frames.count, 3)
        let warm = try service.analyze(assetID: item.assetID)
        XCTAssertEqual(warm.reusedFrameCount, 3)
        XCTAssertEqual(warm.attemptedFrameCount, 0)
        let second = try env.seedAsset(relativePath: "second.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 1_000)
        _ = try service.analyze(assetID: second.assetID)
        XCTAssertThrowsError(try service.analyze(assetID: item.assetID, forceRebuild: true,
            checkCancellation: { throw CancellationError() }))
        XCTAssertEqual(try service.analyze(assetID: item.assetID).reusedFrameCount, 3)
        let forced = try service.analyze(assetID: item.assetID, forceRebuild: true)
        XCTAssertEqual(forced.reusedFrameCount, 0)
        XCTAssertEqual(forced.attemptedFrameCount, 3)
        XCTAssertEqual(try service.analyze(assetID: second.assetID).reusedFrameCount, 3)
        let cache = VideoAnalysisFrameCache(database: env.database, clock: base.clock)
        let key = VideoAnalysisFrameCache.Key(assetID: item.assetID, contentRevision: 1,
            policy: "future-policy", sourceIdentity: "unrelated-source")
        XCTAssertTrue(try cache.frames(key: key).isEmpty)
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?",
                arguments: [item.assetID.uuidString.lowercased()])
        }
        let rebuilt = try service.analyze(assetID: item.assetID)
        XCTAssertEqual(rebuilt.reusedFrameCount, 0)
        XCTAssertEqual(rebuilt.attemptedFrameCount, 3)
        try env.database.pool.write { db in
            try db.execute(sql: "DELETE FROM video_analysis_frame")
        }
        XCTAssertThrowsError(try service.analyze(assetID: item.assetID, onFrame: { _ in
            try (bytes + Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65]))
                .write(to: env.sourceRoot.appendingPathComponent("analysis.mp4"))
        }))
        XCTAssertThrowsError(try service.analyze(assetID: item.assetID))
        print("VIDEO_FRAME_CACHE resumeDecoded=\(resumed.attemptedFrameCount) resumeReused=\(resumed.reusedFrameCount) warmDecoded=\(warm.attemptedFrameCount) revisionDecoded=\(rebuilt.attemptedFrameCount)")
    }

    func testBoundedVideoAnalysisSamplesRealFramesAndCancelsWithoutResult() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let sampler = AVFoundationVideoAnalysisSampler()
        let result = try sampler.sample(sourceFileDescriptorURL: fixture,
            mediaType: "public.mpeg-4", durationMs: 1_000)
        XCTAssertEqual(result.policyIdentity, "videoFrames.uniform5.512.jpeg80.v1")
        XCTAssertGreaterThanOrEqual(result.frames.count, 3)
        XCTAssertLessThanOrEqual(result.attemptedFrameCount, 5)
        XCTAssertEqual(Set(result.frames.map(\.actualTimeMs)).count, result.frames.count)
        XCTAssertLessThanOrEqual(result.encodedByteCount, VideoAnalysisSamplingPolicy.maximumEncodedBytes)
        for frame in result.frames {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpegBytes as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 512)
            XCTAssertLessThanOrEqual(abs(frame.requestedTimeMs - frame.actualTimeMs), 100)
        }
        print("VIDEO_MULTIFRAME_MEASUREMENT frames=\(result.frames.count) attempts=\(result.attemptedFrameCount) bytes=\(result.encodedByteCount) seconds=\(result.elapsedSeconds) actualMs=\(result.frames.map(\.actualTimeMs))")
        var checks = 0
        XCTAssertThrowsError(try sampler.sample(sourceFileDescriptorURL: fixture,
            mediaType: "public.mpeg-4", durationMs: 1_000, checkCancellation: {
                checks += 1
                if checks == 4 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        XCTAssertEqual(VideoAnalysisSamplingPolicy.timestamps(durationMs: 100), [0])
        XCTAssertEqual(VideoAnalysisSamplingPolicy.timestamps(durationMs: 0), [])
        XCTAssertEqual(VideoAnalysisSamplingPolicy.timestamps(durationMs: 10_000), [500, 2_500, 5_000, 7_500, 9_500])
    }

    func testPlayableVideoContainerRewriteIsNotByteIdentical() async throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4")
        let bytes = try Data(contentsOf: fixture)
        // A valid ISO BMFF top-level empty 'free' box changes the container only.
        let rewrittenBytes = bytes + Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65])
        let original = try env.seedAsset(relativePath: "original.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let copy = try env.seedAsset(relativePath: "copy.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let rewritten = try env.seedAsset(relativePath: "rewritten.mp4", contents: rewrittenBytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let base = env.makeCompletionService()
        let service = OriginalVideoDigestService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        let ids = [original.assetID, copy.assetID, rewritten.assetID]
        for id in ids { _ = try service.completeFolderVideo(assetID: id) }
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: ids, mediaKind: .video)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters.first?.memberAssetIDs ?? []), Set([original.assetID, copy.assetID]))
        let first = AVURLAsset(url: env.sourceRoot.appendingPathComponent("original.mp4"))
        let changed = AVURLAsset(url: env.sourceRoot.appendingPathComponent("rewritten.mp4"))
        let firstDuration = try await first.load(.duration)
        let changedDuration = try await changed.load(.duration)
        XCTAssertGreaterThan(firstDuration.seconds, 0)
        XCTAssertEqual(firstDuration.seconds, changedDuration.seconds, accuracy: 0.001)
        let firstFrame = try await AVAssetImageGenerator(asset: first).image(at: .zero)
        let changedFrame = try await AVAssetImageGenerator(asset: changed).image(at: .zero)
        XCTAssertEqual(firstFrame.image.width, changedFrame.image.width)
        XCTAssertEqual(firstFrame.image.height, changedFrame.image.height)
        let firstPixels = try XCTUnwrap(firstFrame.image.dataProvider?.data) as Data
        let changedPixels = try XCTUnwrap(changedFrame.image.dataProvider?.data) as Data
        XCTAssertEqual(Data(SHA256.hash(data: firstPixels)), Data(SHA256.hash(data: changedPixels)))
        XCTAssertNotEqual(Data(SHA256.hash(data: bytes)), Data(SHA256.hash(data: rewrittenBytes)))
    }

    func testPhotoKitOriginalVideoJobGroupsResourcesAndExplainsCloudAndEditedResults() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = Data(repeating: 23, count: 700_001)
        let folder = try env.seedAsset(relativePath: "copy.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let photos = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video)
        let edited = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video)
        let cloud = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video)
        let reader = SyntheticPhotosVideoDigestReader(bytes: bytes)
        reader.cloudIDs = ["LOCAL-\(cloud.uuidString.lowercased())"]
        reader.editedIDs = ["LOCAL-\(edited.uuidString.lowercased())"]
        let base = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let completion = FingerprintCompletionService(database: env.database, sourceAccess: base.sourceAccess,
            photosVideoOriginals: reader, clock: base.clock, videoPosterGenerator: SimilarityVideoPosterStub())
        let features = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddings = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let queue = JobTestSupport.makeQueue(database: env.database)
        let scanner = LibrarySlimmingScanService(database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database), fingerprintCompletion: completion,
            featureLoader: features, embeddingLoader: embeddings)
        let analysis = LibrarySlimmingAnalysisService(database: env.database, queue: queue,
            fingerprintCompletion: completion, featureLoader: features, embeddingLoader: embeddings,
            scanner: scanner, clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs))
        let job = try analysis.enqueue(mode: .catalog, assetIDs: [folder.assetID, photos, edited, cloud],
            seedAssetIDs: [], mediaKind: .video)
        try analysis.runPending()
        let finished = try analysis.snapshot(jobID: job.jobID)
        XCTAssertEqual(finished.state, .completed)
        let exact = try XCTUnwrap(finished.result?.clusters.first { $0.kind == .byteIdentical })
        XCTAssertEqual(Set(exact.memberAssetIDs), Set([folder.assetID, photos, edited]))
        let summary = try XCTUnwrap(finished.result?.photosOriginalVideoSummary)
        XCTAssertEqual(summary.cloudOnlyCount, 1)
        XCTAssertEqual(summary.adjustedOriginalCount, 1)
        XCTAssertTrue(summary.caption?.contains("未下载") == true)
        XCTAssertTrue(summary.caption?.contains("编辑结果") == true)
        XCTAssertEqual(reader.calls, 3, "Poster completion retries must not reread entire Photos resources")
        XCTAssertEqual(LibrarySlimmingClusterPresentation(exact, mediaKind: .video).kindTitle, "视频原件相同")
        let rows = try env.database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT status, sha256 FROM asset_photos_original_video_digest")
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter { ($0["status"] as String) == "verified" }.count, 2)
        XCTAssertNil(rows.first { ($0["status"] as String) == "cloudOnly" }?["sha256"] as Data?)
        let progress = LibrarySlimmingScanProgress(phase: .preparingFingerprints, completed: 0, total: 1,
            completedBytes: 256 * 1024, totalBytes: 0)
        XCTAssertTrue(progress.caption.contains("已读取"))
    }

    func testPhotoKitOriginalVideoCancellationRevisionAndCloudRefreshDiscardOldProof() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video)
        let reader = SyntheticPhotosVideoDigestReader(bytes: Data(repeating: 13, count: 500_000))
        let service = PhotosOriginalVideoDigestService(database: env.database, reader: reader,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs))
        func evidenceCount() throws -> Int {
            try env.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_photos_original_video_digest WHERE status = 'verified'") ?? 0
            }
        }
        try service.complete(assetID: asset)
        XCTAssertEqual(try evidenceCount(), 1)
        var checks = 0
        XCTAssertThrowsError(try service.complete(assetID: asset, checkCancellation: {
            checks += 1
            if checks > 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try evidenceCount(), 0)
        try service.complete(assetID: asset)
        reader.cloudIDs = ["LOCAL-\(asset.uuidString.lowercased())"]
        try service.complete(assetID: asset)
        XCTAssertEqual(try evidenceCount(), 0)
        XCTAssertEqual(try PhotosOriginalVideoDigestService.summary(database: env.database, assetIDs: [asset]).cloudOnlyCount, 1)
        reader.cloudIDs = []
        reader.onCompletedRead = {
            try env.database.pool.write { db in
                try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?",
                    arguments: [asset.uuidString.lowercased()])
            }
        }
        try service.complete(assetID: asset)
        XCTAssertEqual(try evidenceCount(), 0)
    }

    func testLegacyExplicitVideoMethodDoesNotReadPhotoKitOriginals() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedPhotosAsset(mediaType: "public.mpeg-4", mediaKind: .video)
        let base = env.makeCompletionService()
        let reader = SyntheticPhotosVideoDigestReader(bytes: Data([1, 2, 3]))
        let completion = FingerprintCompletionService(database: env.database, sourceAccess: base.sourceAccess,
            photosVideoOriginals: reader, clock: base.clock)
        _ = try? completion.completeExplicitAnalysisAsset(assetID: asset,
            checkCancellation: {}, onByteProgress: { _, _ in })
        XCTAssertEqual(reader.calls, 0)
        let legacy = Data(#"{"mode":"catalog","mediaKind":"video","originalVideoDigestPolicy":"folder-original-sha256-v1"}"#.utf8)
        XCTAssertEqual(try LibrarySlimmingAnalysisJobFactory.decodePayload(legacy).originalVideoDigestPolicy,
            OriginalVideoDigestService.policy)
    }

    func testExplicitVideoAnalysisJobPausesInsideOriginalReadThenResumesToExactResult() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = Data(repeating: 1, count: OriginalVideoDigestService.chunkByteCount * 3)
        let a = try env.seedAsset(relativePath: "a.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let b = try env.seedAsset(relativePath: "b.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: nil)
        let base = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let completion = ExplicitVideoAnalysisTestCompletion(base: base)
        let features = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddings = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let queue = JobTestSupport.makeQueue(database: env.database)
        let scanner = LibrarySlimmingScanService(database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database), fingerprintCompletion: base,
            featureLoader: features, embeddingLoader: embeddings)
        let analysis = LibrarySlimmingAnalysisService(database: env.database, queue: queue,
            fingerprintCompletion: completion, featureLoader: features, embeddingLoader: embeddings,
            scanner: scanner, clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs))
        let job = try analysis.enqueue(mode: .catalog, assetIDs: [a.assetID, b.assetID], seedAssetIDs: [], mediaKind: .video)
        var requested = false
        completion.onChunk = { done, _ in
            guard done > 0, !requested else { return }
            requested = true
            let running = try analysis.snapshot(jobID: job.jobID)
            XCTAssertNotNil(running.scanProgress?.totalBytes)
            _ = try analysis.pause(jobID: job.jobID)
        }
        try analysis.runPending()
        let paused = try analysis.snapshot(jobID: job.jobID)
        XCTAssertTrue(requested)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNil(paused.result)
        XCTAssertEqual(try env.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest") }, 0)
        completion.onChunk = nil
        _ = try analysis.resume(jobID: job.jobID)
        try analysis.runPending()
        let finished = try analysis.snapshot(jobID: job.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.result?.clusters.map(\.kind), [.byteIdentical])
        XCTAssertEqual(Set(finished.result?.clusters.first?.memberAssetIDs ?? []), Set([a.assetID, b.assetID]))
        XCTAssertEqual(try env.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest") }, 2)
        let digestService = OriginalVideoDigestService(database: env.database, sourceAccess: base.sourceAccess, clock: base.clock)
        XCTAssertTrue(try digestService.completeFolderVideo(assetID: a.assetID).reused)
    }

    func testExplicitVideoAnalysisCancellationPublishesNeitherDigestNorResult() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedAsset(relativePath: "cancel.mp4",
            contents: Data(repeating: 1, count: OriginalVideoDigestService.chunkByteCount * 2),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let base = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let completion = ExplicitVideoAnalysisTestCompletion(base: base)
        let features = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddings = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let queue = JobTestSupport.makeQueue(database: env.database)
        let scanner = LibrarySlimmingScanService(database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database), fingerprintCompletion: base,
            featureLoader: features, embeddingLoader: embeddings)
        let analysis = LibrarySlimmingAnalysisService(database: env.database, queue: queue,
            fingerprintCompletion: completion, featureLoader: features, embeddingLoader: embeddings,
            scanner: scanner, clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs))
        let job = try analysis.enqueue(mode: .catalog, assetIDs: [asset.assetID], seedAssetIDs: [], mediaKind: .video)
        completion.onChunk = { done, _ in
            if done > 0 { _ = try queue.applyStateCommand(.init(jobID: job.jobID, operation: .cancel)) }
        }
        try analysis.runPending()
        let cancelled = try analysis.snapshot(jobID: job.jobID)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertNil(cancelled.result)
        XCTAssertEqual(try env.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest") }, 0)
    }

    func testLegacyVideoAnalysisDoesNotAcquireOriginalByteAuthorityOnResume() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedAsset(relativePath: "legacy.mp4", contents: Data([1, 2, 3]),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let base = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let completion = ExplicitVideoAnalysisTestCompletion(base: base)
        completion.onChunk = { _, _ in XCTFail("legacy job must not read full video bytes") }
        let features = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddings = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let queue = JobTestSupport.makeQueue(database: env.database)
        let scanner = LibrarySlimmingScanService(database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database), fingerprintCompletion: base,
            featureLoader: features, embeddingLoader: embeddings)
        let analysis = LibrarySlimmingAnalysisService(database: env.database, queue: queue,
            fingerprintCompletion: completion, featureLoader: features, embeddingLoader: embeddings,
            scanner: scanner, clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs))
        let job = try analysis.enqueue(mode: .catalog, assetIDs: [asset.assetID], seedAssetIDs: [], mediaKind: .video)
        let legacy = Data(#"{"mode":"catalog","mediaKind":"video"}"#.utf8)
        XCTAssertNil(try LibrarySlimmingAnalysisJobFactory.decodePayload(legacy).originalVideoDigestPolicy)
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE job SET payload = ? WHERE id = ?", arguments: [legacy, job.jobID.uuidString.lowercased()])
        }
        _ = try analysis.pause(jobID: job.jobID)
        _ = try analysis.resume(jobID: job.jobID)
        try analysis.runPending()
        XCTAssertEqual(try analysis.snapshot(jobID: job.jobID).state, .completed)
        XCTAssertEqual(try env.database.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest") }, 0)
        let unknown = Data(#"{"mode":"catalog","mediaKind":"video","originalVideoDigestPolicy":"unknown"}"#.utf8)
        XCTAssertThrowsError(try LibrarySlimmingAnalysisJobFactory.decodePayload(unknown))
    }

    func testExplicitOriginalVideoDigestStreamsReusesAndKeepsPosterIndependent() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = Data((0..<(OriginalVideoDigestService.chunkByteCount * 3 + 71)).map { UInt8($0 % 251) })
        let asset = try env.seedAsset(relativePath: "original.mp4", contents: bytes,
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let completion = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let poster = try completion.completeAsset(assetID: asset.assetID)
        let service = OriginalVideoDigestService(database: env.database,
            sourceAccess: completion.sourceAccess, clock: completion.clock)
        var counts: [Int64] = []
        let first = try service.completeFolderVideo(assetID: asset.assetID, onProgress: { done, total in
            XCTAssertEqual(total, Int64(bytes.count)); counts.append(done)
        })
        XCTAssertEqual(first.sha256, Data(SHA256.hash(data: bytes)))
        XCTAssertFalse(first.reused)
        XCTAssertEqual(counts, [0, 262_144, 524_288, 786_432, 786_503])
        let reused = try service.completeFolderVideo(assetID: asset.assetID)
        XCTAssertTrue(reused.reused)
        XCTAssertEqual(reused.sha256, first.sha256)
        XCTAssertEqual(try completion.completeAsset(assetID: asset.assetID), poster)
        XCTAssertNotEqual(poster.sha256, first.sha256)
        let rows = try env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest")
        }
        XCTAssertEqual(rows, 1)
    }

    func testOriginalVideoDigestRejectsCancellationMutationReplacementAndRevisionRace() throws {
        for scenario in 0..<4 {
            let env = try SimilarityTestSupport.Environment(label: "\(#function)-\(scenario)")
            defer { env.cleanup() }
            let bytes = Data(repeating: 17, count: OriginalVideoDigestService.chunkByteCount * 2 + 7)
            let asset = try env.seedAsset(relativePath: "video.mp4", contents: bytes,
                mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
            let completion = env.makeCompletionService()
            let service = OriginalVideoDigestService(database: env.database,
                sourceAccess: completion.sourceAccess, clock: completion.clock)
            var changed = false
            XCTAssertThrowsError(try service.completeFolderVideo(assetID: asset.assetID,
                checkCancellation: { if scenario == 0 && changed { throw CancellationError() } },
                onProgress: { done, _ in
                    guard done > 0, !changed else { return }
                    changed = true
                    switch scenario {
                    case 1:
                        let handle = try FileHandle(forWritingTo: asset.fileURL)
                        defer { try? handle.close() }
                        try handle.write(contentsOf: Data([99]))
                    case 2:
                        let replacement = env.sourceRoot.appendingPathComponent("replacement.mp4")
                        try bytes.write(to: replacement)
                        try FileManager.default.removeItem(at: asset.fileURL)
                        try FileManager.default.moveItem(at: replacement, to: asset.fileURL)
                    case 3:
                        try env.database.pool.write { db in
                            try db.execute(sql: "UPDATE asset SET content_revision = content_revision + 1 WHERE id = ?",
                                arguments: [asset.assetID.uuidString.lowercased()])
                        }
                    default: break
                    }
                })) { error in
                    if scenario == 0 { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? FingerprintCompletionError, .sourceChanged) }
                }
            XCTAssertEqual(try env.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_original_content_digest")
            }, 0)
        }
    }

    func testOriginalVideoDigestDoesNotReuseAfterWriteWithRestoredModificationTime() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedAsset(relativePath: "video.mp4", contents: Data(repeating: 1, count: 100),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let completion = env.makeCompletionService()
        let service = OriginalVideoDigestService(database: env.database,
            sourceAccess: completion.sourceAccess, clock: completion.clock)
        let first = try service.completeFolderVideo(assetID: asset.assetID)
        var original = stat()
        XCTAssertEqual(stat(asset.fileURL.path, &original), 0)
        let handle = try FileHandle(forWritingTo: asset.fileURL)
        try handle.write(contentsOf: Data(repeating: 2, count: 100))
        try handle.close()
        var times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, asset.fileURL.path, &times, 0), 0)
        let second = try service.completeFolderVideo(assetID: asset.assetID)
        XCTAssertFalse(second.reused)
        XCTAssertNotEqual(second.sha256, first.sha256)
    }

    func testVideoExactGroupsRequireFullBytesAndCurrentRevisionWithoutPosterDependency() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let a = try env.seedAsset(relativePath: "a.mp4", contents: Data([1, 2, 3]),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let copy = try env.seedAsset(relativePath: "copy.mp4", contents: Data([1, 2, 3]),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let different = try env.seedAsset(relativePath: "same-poster.mp4", contents: Data([1, 7, 8]),
            mediaType: "public.mpeg-4", mediaKind: .video, durationMs: 4_000)
        let container = try env.seedAsset(relativePath: "rewrapped.mov", contents: Data([1, 2, 3, 0]),
            mediaType: "com.apple.quicktime-movie", mediaKind: .video, durationMs: 4_000)
        let completion = env.makeCompletionService(videoPosterGenerator: SimilarityVideoPosterStub())
        let service = OriginalVideoDigestService(database: env.database,
            sourceAccess: completion.sourceAccess, clock: completion.clock)
        let ids = [a.assetID, copy.assetID, different.assetID, container.assetID]
        for id in ids { _ = try service.completeFolderVideo(assetID: id) }
        let clusterer = IdenticalDuplicateClusterService(database: env.database)
        let withoutPosters = try clusterer.clusterIdenticalDuplicates(assetIDs: ids, mediaKind: .video)
        XCTAssertEqual(withoutPosters.count, 1)
        XCTAssertEqual(withoutPosters.first?.kind, .byteIdentical)
        XCTAssertEqual(Set(withoutPosters.first?.memberAssetIDs ?? []), Set([a.assetID, copy.assetID]))
        for id in ids { _ = try completion.completeAsset(assetID: id) }
        let withPosters = try clusterer.clusterIdenticalDuplicates(assetIDs: ids, mediaKind: .video)
        XCTAssertEqual(withPosters.filter { $0.kind == .byteIdentical }, withoutPosters)
        XCTAssertEqual(withPosters.filter { $0.kind == .perceptualDuplicate }.count, 1)
        XCTAssertTrue(try clusterer.clusterIdenticalDuplicates(assetIDs: ids, mediaKind: .image).isEmpty)
        try env.database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = 2 WHERE id = ?", arguments: [copy.assetID.uuidString.lowercased()])
        }
        XCTAssertFalse(try clusterer.clusterIdenticalDuplicates(assetIDs: ids, mediaKind: .video).contains { $0.kind == .byteIdentical })
    }

    func testVideoFingerprintUsesOnlyRepresentativePosterAcrossFolderAndPhotoKit() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let videoBytes = Data([1, 7, 7, 7])
        let folder = try env.seedAsset(
            relativePath: "folder-video.mp4",
            contents: videoBytes,
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let photosAssetID = try env.seedPhotosAsset(
            mediaType: "com.apple.quicktime-movie",
            mediaKind: .video,
            durationMs: 4_000
        )
        let posterBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 101, uti: .png)
        )
        let featureImages = SimilarityPhotosFeatureImageStub(bytes: posterBytes)
        let completion = env.makeCompletionService(
            photosFeatureImages: featureImages,
            videoPosterGenerator: SimilarityVideoPosterStub()
        )

        let folderFingerprint = try completion.completeAsset(assetID: folder.assetID)
        let photosFingerprint = try completion.completeAsset(assetID: photosAssetID)

        XCTAssertEqual(photosFingerprint.sha256, folderFingerprint.sha256)
        XCTAssertNotEqual(folderFingerprint.sha256, Data(SHA256.hash(data: videoBytes)))
        XCTAssertEqual(
            photosFingerprint.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )
        XCTAssertEqual(featureImages.requestCount, 1)
        let storedFileSHA: Data? = try env.database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sha256 FROM file_fingerprint WHERE asset_id = ?",
                arguments: [folder.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(storedFileSHA)

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(
                assetIDs: [folder.assetID, photosAssetID],
                mediaKind: .video
            )
        XCTAssertEqual(clusters.map(\.kind), [.perceptualDuplicate])
        XCTAssertEqual(
            Set(try XCTUnwrap(clusters.first).memberAssetIDs),
            Set([folder.assetID, photosAssetID])
        )
    }

    func testVideoSlimmingUsesOnlyPosterSimilarityWithoutPhotoLeakage() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let exactA = try env.seedAsset(
            relativePath: "exact-a.mp4",
            contents: Data([1, 9, 9, 9]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let exactB = try env.seedAsset(
            relativePath: "exact-b.mp4",
            contents: Data([1, 8, 8, 8]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let sceneA = try env.seedAsset(
            relativePath: "scene-a.mp4",
            contents: Data([2, 2, 3]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 5_000
        )
        let sceneB = try env.seedAsset(
            relativePath: "scene-b.mp4",
            contents: Data([3, 3, 4]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 6_000
        )
        let photoBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 88, uti: .jpeg)
        )
        let photo = try env.seedAsset(relativePath: "photo.jpg", contents: photoBytes)

        let completion = env.makeCompletionService(
            videoPosterGenerator: SimilarityVideoPosterStub()
        )
        for assetID in [exactA.assetID, exactB.assetID, sceneA.assetID, sceneB.assetID, photo.assetID] {
            _ = try completion.completeAsset(assetID: assetID)
        }

        let exactFingerprint = try completion.completeAsset(assetID: exactA.assetID)
        XCTAssertEqual(
            exactFingerprint.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )
        XCTAssertEqual(
            try completion.completeAsset(assetID: photo.assetID).perceptualAlgoVersion,
            IdenticalDuplicatePolicy.perceptualAlgoVersion
        )

        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            sceneA.assetID: [1, 0],
            sceneB.assetID: [0.99, 0.01],
            photo.assetID: [0.98, 0.02],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            sceneA.assetID: [1, 0],
            sceneB.assetID: [0.99, 0.01],
            photo.assetID: [0.98, 0.02],
        ])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )

        let result = try scanner.scan(
            assetIDs: [
                exactA.assetID, exactB.assetID,
                sceneA.assetID, sceneB.assetID,
                photo.assetID,
            ],
            mediaKind: .video,
            onProgress: nil
        )

        XCTAssertEqual(result.analyzedAssetCount, 4)
        XCTAssertFalse(result.clusters.contains { $0.kind == .byteIdentical })
        let posterDuplicate = try XCTUnwrap(
            result.clusters.first {
                $0.kind == .perceptualDuplicate
                    && Set($0.memberAssetIDs) == Set([exactA.assetID, exactB.assetID])
            },
            """
            exactA=\(exactA.assetID) exactB=\(exactB.assetID) \
            sceneA=\(sceneA.assetID) sceneB=\(sceneB.assetID) \
            clusters=\(result.clusters.map { ($0.kind, $0.memberAssetIDs) })
            """
        )
        XCTAssertEqual(posterDuplicate.score, 1)
        let similar = try XCTUnwrap(result.clusters.first { $0.kind == .nearDuplicateScene })
        XCTAssertEqual(Set(similar.memberAssetIDs), Set([sceneA.assetID, sceneB.assetID]))
        XCTAssertFalse(result.clusters.flatMap(\.memberAssetIDs).contains(photo.assetID))
        XCTAssertEqual(
            posterDuplicate.modelIdentity.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )

        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [exactA.assetID, exactB.assetID, sceneA.assetID, sceneB.assetID],
            seedAssetIDs: [],
            mediaKind: .video
        )
        try analysis.runPending()
        let completed = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.result?.analyzedAssetCount, 4)
        XCTAssertEqual(try analysis.listJobs(mediaKind: .video).count, 1)
        XCTAssertTrue(try analysis.listJobs(mediaKind: .image).isEmpty)
    }

    func testByteIdenticalClusterAndSourceUnchanged() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 11, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "a.jpg", contents: bytes)
        let b = try env.seedAsset(relativePath: "b.jpg", contents: bytes)
        let beforeA = try env.sourceFileSnapshot(for: a.fileURL)
        let beforeB = try env.sourceFileSnapshot(for: b.fileURL)

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertEqual(fa.sha256, fb.sha256)
        XCTAssertEqual(fa.sha256.count, 32)

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .byteIdentical)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a.assetID, b.assetID]))

        XCTAssertEqual(try env.sourceFileSnapshot(for: a.fileURL), beforeA)
        XCTAssertEqual(try env.sourceFileSnapshot(for: b.fileURL), beforeB)
    }

    func testPerceptualDuplicateAcrossJPEGAndPNG() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let jpeg = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 42, uti: .jpeg, quality: 0.95))
        let png = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 42, uti: .png))
        XCTAssertNotEqual(jpeg, png)

        let a = try env.seedAsset(relativePath: "same-a.jpg", contents: jpeg, mediaType: "public.jpeg")
        let b = try env.seedAsset(relativePath: "same-b.png", contents: png, mediaType: "public.png")

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertNotEqual(fa.sha256, fb.sha256)

        let left = try XCTUnwrap(PerceptualImageHash.decodeHash(fa.perceptualHash))
        let right = try XCTUnwrap(PerceptualImageHash.decodeHash(fb.perceptualHash))
        let distance = PerceptualImageHash.hammingDistance(left, right)
        XCTAssertLessThanOrEqual(
            distance,
            IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        )

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .perceptualDuplicate)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a.assetID, b.assetID]))
    }

    func testClearlyDifferentImagesDoNotCluster() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let leftBytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 1, uti: .jpeg))
        let rightBytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 200, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "left.jpg", contents: leftBytes)
        let b = try env.seedAsset(relativePath: "right.jpg", contents: rightBytes)

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertNotEqual(fa.sha256, fb.sha256)

        let left = try XCTUnwrap(PerceptualImageHash.decodeHash(fa.perceptualHash))
        let right = try XCTUnwrap(PerceptualImageHash.decodeHash(fb.perceptualHash))
        XCTAssertGreaterThan(
            PerceptualImageHash.hammingDistance(left, right),
            IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        )

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertTrue(clusters.isEmpty)
    }

    func testDifferentSolidColorsDoNotBecomeDeletionGradeDuplicates() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let red = try XCTUnwrap(
            SimilarityTestSupport.solidImageData(red: 230, green: 20, blue: 20, uti: .jpeg)
        )
        let blue = try XCTUnwrap(
            SimilarityTestSupport.solidImageData(red: 20, green: 20, blue: 230, uti: .jpeg)
        )
        let a = try env.seedAsset(relativePath: "red.jpg", contents: red)
        let b = try env.seedAsset(relativePath: "blue.jpg", contents: blue)
        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertEqual(fa.perceptualHash, fb.perceptualHash, "fixture must exercise a dHash collision")

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])

        XCTAssertTrue(clusters.isEmpty)
    }

    func testPhotosCloudOriginalIsDurablyCachedAndClustersAcrossSources() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 77, uti: .png))
        let folderAsset = try env.seedAsset(
            relativePath: "same-as-photos.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let photos = SimilarityPhotosOriginalStub(bytes: bytes)
        let completion = env.makeCompletionService(photosOriginals: photos)

        let photoFingerprint = try completion.completeAsset(assetID: photosAssetID)
        let folderFingerprint = try completion.completeAsset(assetID: folderAsset.assetID)

        XCTAssertEqual(photoFingerprint.sha256, folderFingerprint.sha256)
        XCTAssertEqual(photos.requestCount, 1)
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [photosAssetID, folderAsset.assetID])
        XCTAssertEqual(clusters.map(\.kind), [.byteIdentical])

        try env.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM asset_similarity_fingerprint WHERE asset_id = ?",
                arguments: [photosAssetID.uuidString.lowercased()]
            )
        }
        photos.bytes = nil
        _ = try completion.completeAsset(assetID: photosAssetID)
        XCTAssertEqual(photos.requestCount, 1, "second completion must use the durable local original")
    }

    func testPhotosFingerprintFallsBackToLocalFeatureImageWhenOriginalIsCloudOnly() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let previewBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 44, uti: .jpeg)
        )
        let folderAsset = try env.seedAsset(
            relativePath: "same-preview-bytes.jpg",
            contents: previewBytes
        )
        let originals = SimilarityPhotosOriginalStub(error: .cloudOnly)
        let featureImages = SimilarityPhotosFeatureImageStub(bytes: previewBytes)
        let completion = env.makeCompletionService(
            photosOriginals: originals,
            photosFeatureImages: featureImages
        )
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        let fingerprint = try completion.completeAsset(assetID: photosAssetID)
        _ = try completion.completeAsset(assetID: folderAsset.assetID)
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [photosAssetID, folderAsset.assetID])

        XCTAssertEqual(originals.requestCount, 1)
        XCTAssertEqual(featureImages.requestCount, 1)
        XCTAssertEqual(try cache.storageUsage(), .zero, "preview/thumbnail bytes must not be stored as originals")
        XCTAssertEqual(fingerprint.sha256, Data(SHA256.hash(data: previewBytes)))
        XCTAssertFalse(
            clusters.contains { $0.kind == .byteIdentical },
            "feature/preview bytes must never prove deletion-grade byte identity"
        )
    }

    func testPhotosExactAnalysisRequiresConfiguredLocationBeforePhotoKitRequest() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 79, uti: .png))
        let photos = SimilarityPhotosOriginalStub(bytes: bytes)
        let completion = env.makeCompletionService(
            photosOriginals: photos,
            retainsPhotosOriginals: false
        )

        XCTAssertThrowsError(
            try completion.validatePrerequisites(assetIDs: [photosAssetID])
        ) { error in
            XCTAssertEqual(
                error as? FingerprintCompletionError,
                .photosOriginalStorageNotConfigured
            )
        }
        XCTAssertThrowsError(try completion.completeAsset(assetID: photosAssetID)) { error in
            XCTAssertEqual(
                error as? FingerprintCompletionError,
                .photosOriginalStorageNotConfigured
            )
        }

        XCTAssertEqual(photos.requestCount, 0)
        let cacheRows = try env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos_original_cache_entry") ?? 0
        }
        XCTAssertEqual(cacheRows, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: env.root.appendingPathComponent("Photos Originals").path
            )
        )
    }

    func testLibraryAnalysisJobIsNotCreatedWhenPhotosOriginalStorageIsUnconfigured() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let completion = env.makeCompletionService(
            photosOriginals: SimilarityPhotosOriginalStub(bytes: Data([1, 2, 3])),
            retainsPhotosOriginals: false
        )
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        XCTAssertThrowsError(
            try analysis.enqueue(
                mode: .catalog,
                assetIDs: [photosAssetID],
                seedAssetIDs: []
            )
        ) { error in
            XCTAssertEqual(
                error as? FingerprintCompletionError,
                .photosOriginalStorageNotConfigured
            )
        }
        XCTAssertTrue(try analysis.listJobs().isEmpty)
    }

    func testPhotosFingerprintSkipsWhenNoLocalBytesAvailable() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let completion = env.makeCompletionService(
            photosOriginals: SimilarityPhotosOriginalStub(error: .cloudOnly),
            photosFeatureImages: SimilarityPhotosFeatureImageStub(error: .cloudOnly)
        )

        XCTAssertThrowsError(try completion.completeAsset(assetID: photosAssetID)) { error in
            XCTAssertEqual(error as? FingerprintCompletionError, .sourceUnavailable)
        }
    }

    func testDurablePhotosOriginalCacheRejectsPreviewWrites() async throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        do {
            _ = try await cache.storeDownloadedPreview(
                assetID: photosAssetID,
                sourceBytes: Data("preview-only".utf8)
            )
            XCTFail("preview bytes must never be persisted as a durable original")
        } catch PhotosOriginalCacheError.previewWriteRejected {
            // Expected: the protocol conformance is read-only.
        }
    }

    func testDurablePhotosOriginalCacheRejectsChangedPhotoLocator() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        XCTAssertThrowsError(
            try cache.store(
                assetID: photosAssetID,
                contentRevision: 1,
                localIdentifier: "stale-photo-identifier",
                mediaType: "public.jpeg",
                sourceBytes: Data("full-original".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? PhotosOriginalCacheError, .assetChanged)
        }
    }

    func testDurablePhotosOriginalStorageReportsRetainedUsage() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let original = Data("retained-full-original".utf8)
        let localIdentifier = "LOCAL-\(photosAssetID.uuidString.lowercased())"

        _ = try cache.store(
            assetID: photosAssetID,
            contentRevision: 1,
            localIdentifier: localIdentifier,
            mediaType: "public.jpeg",
            sourceBytes: original
        )

        XCTAssertEqual(
            try cache.storageUsage(),
            PhotosOriginalStorageUsage(
                entryCount: 1,
                registeredBytes: Int64(original.count)
            )
        )
    }

    func testUnconfiguredUpgradeCanReadAndClearLegacyPhotosOriginal() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let legacyRoot = env.root.appendingPathComponent("Legacy Photos Originals", isDirectory: true)
        let legacyCache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: legacyRoot,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let original = Data("legacy-full-original".utf8)
        let localIdentifier = "LOCAL-\(photosAssetID.uuidString.lowercased())"
        _ = try legacyCache.store(
            assetID: photosAssetID,
            contentRevision: 1,
            localIdentifier: localIdentifier,
            mediaType: "public.jpeg",
            sourceBytes: original
        )
        let upgradedCache = PhotosOriginalCacheService(
            database: env.database,
            configuredRootURL: nil,
            legacyRootURLs: [legacyRoot],
            accessLease: nil,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        XCTAssertEqual(
            try upgradedCache.load(
                assetID: photosAssetID,
                contentRevision: 1,
                localIdentifier: localIdentifier
            ),
            original
        )
        XCTAssertEqual(
            try upgradedCache.clearAll(),
            PhotosOriginalStorageClearResult(
                removedEntries: 1,
                removedBytes: Int64(original.count),
                partialReclaim: false
            )
        )
        XCTAssertEqual(try upgradedCache.storageUsage(), .zero)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: legacyRoot.path),
            []
        )
    }

    func testManualDurablePhotosOriginalClearKeepsCatalogAndFingerprintFacts() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let original = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 91, uti: .jpeg)
        )
        let photos = SimilarityPhotosOriginalStub(bytes: original)
        let completion = env.makeCompletionService(photosOriginals: photos)
        let localIdentifier = "LOCAL-\(photosAssetID.uuidString.lowercased())"
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        _ = try completion.completeAsset(assetID: photosAssetID)
        XCTAssertEqual(try cache.storageUsage().entryCount, 1)

        XCTAssertEqual(
            try cache.clearAll(),
            PhotosOriginalStorageClearResult(
                removedEntries: 1,
                removedBytes: Int64(original.count),
                partialReclaim: false
            )
        )
        XCTAssertEqual(try cache.storageUsage(), .zero)
        XCTAssertNil(
            try cache.load(
                assetID: photosAssetID,
                contentRevision: 1,
                localIdentifier: localIdentifier
            )
        )
        let fingerprintCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset_similarity_fingerprint WHERE asset_id = ?",
                arguments: [photosAssetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(fingerprintCount, 1)
        XCTAssertEqual(photos.requestCount, 1)
    }

    func testManualDurablePhotosOriginalClearRejectsSymlinkObject() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let root = env.root.appendingPathComponent("Photos Originals", isDirectory: true)
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: root,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        _ = try cache.store(
            assetID: photosAssetID,
            contentRevision: 1,
            localIdentifier: "LOCAL-\(photosAssetID.uuidString.lowercased())",
            mediaType: "public.jpeg",
            sourceBytes: Data("registered-original".utf8)
        )
        let objectName = try env.database.pool.read { db in
            try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT object_name FROM photos_original_cache_entry WHERE asset_id = ?",
                    arguments: [photosAssetID.uuidString.lowercased()]
                )
            )
        }
        let objectURL = root.appendingPathComponent(objectName)
        let sentinelURL = env.root.appendingPathComponent("must-survive.txt")
        let sentinel = Data("user-owned-sentinel".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.removeItem(at: objectURL)
        try FileManager.default.createSymbolicLink(
            at: objectURL,
            withDestinationURL: sentinelURL
        )

        XCTAssertEqual(
            try cache.clearAll(),
            PhotosOriginalStorageClearResult(
                removedEntries: 0,
                removedBytes: 0,
                partialReclaim: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(try cache.storageUsage().entryCount, 1)
    }

    func testPrioritizedPreviewCacheReadsDurableOriginalAndWritesDisposableFallback() async throws {
        let assetID = UUID()
        let original = Data("durable-original".utf8)
        let preview = Data("disposable-preview".utf8)
        let primary = SimilarityDownloadedPreviewCacheStub(loaded: original)
        let fallback = SimilarityDownloadedPreviewCacheStub(loaded: preview)
        let cache = PrioritizedDownloadedPreviewCache(primary: primary, fallback: fallback)

        XCTAssertEqual(try cache.loadDownloadedPreview(assetID: assetID), original)
        XCTAssertEqual(primary.loadCount, 1)
        XCTAssertEqual(fallback.loadCount, 0)

        let storedPreview = try await cache.storeDownloadedPreview(
            assetID: assetID,
            sourceBytes: preview
        )
        XCTAssertEqual(storedPreview, preview)
        XCTAssertEqual(primary.storeCount, 0)
        XCTAssertEqual(fallback.storeCount, 1)
    }

    func testV018MigrationAppliedOnFreshDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-S1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("asset_similarity_fingerprint"))
        }
    }

    func testLibraryAnalysisJobPausesResumesAndPersistsAutomaticCompletion() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 91, uti: .png))
        let left = try env.seedAsset(relativePath: "job-left.png", contents: bytes, mediaType: "public.png")
        let right = try env.seedAsset(relativePath: "job-right.png", contents: bytes, mediaType: "public.png")
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [left.assetID, right.assetID],
            seedAssetIDs: []
        )
        XCTAssertEqual(enqueued.state, .pending)
        XCTAssertEqual(try analysis.pause(jobID: enqueued.jobID).state, .paused)
        XCTAssertEqual(try analysis.resume(jobID: enqueued.jobID).state, .pending)

        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.result?.clusters.map(\.kind), [.byteIdentical])
        XCTAssertEqual(finished.result?.pendingAnalysisAssetIDs, [])
    }

    func testLibrarySlimmingClusterReviewQueuePersistsMovesAndClears() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let asset = try env.seedAsset(
            relativePath: "review-queue.jpg",
            contents: Data([1, 2, 3]),
            mediaType: "public.jpeg"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        let job = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )
        let clusterID = UUID()

        try analysis.setClusterReviewDisposition(
            jobID: job.jobID,
            clusterID: clusterID,
            disposition: .confirmed
        )
        XCTAssertEqual(
            try analysis.clusterReviewDispositions(jobID: job.jobID),
            [clusterID: .confirmed]
        )

        try analysis.setClusterReviewDisposition(
            jobID: job.jobID,
            clusterID: clusterID,
            disposition: .ignored
        )
        XCTAssertEqual(
            try analysis.clusterReviewDispositions(jobID: job.jobID),
            [clusterID: .ignored]
        )

        try analysis.setClusterReviewDisposition(
            jobID: job.jobID,
            clusterID: clusterID,
            disposition: nil
        )
        XCTAssertTrue(try analysis.clusterReviewDispositions(jobID: job.jobID).isEmpty)
    }

    func testLibraryAnalysisResumeKeepsAlreadyPendingJobClaimable() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 94, uti: .png))
        let asset = try env.seedAsset(
            relativePath: "already-pending.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        let resumed = try analysis.resume(jobID: enqueued.jobID)

        XCTAssertEqual(resumed.state, .pending)
        XCTAssertEqual(
            try JobTestSupport.claimDefault(queue: queue)?.jobID,
            enqueued.jobID
        )
    }

    func testLibraryAnalysisResumeRecoversExpiredRunningJob() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 97, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "expired-running.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let clock = MutableJobClock(nowMs: JobTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: JobTestSupport.retryDelayMs)
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        XCTAssertEqual(lease.jobID, enqueued.jobID)
        clock.setNowMs(lease.leaseExpiresAtMs + 1)

        let resumed = try analysis.resume(jobID: enqueued.jobID)

        XCTAssertEqual(resumed.state, .pending)
        XCTAssertNil(try queue.fetchJob(id: enqueued.jobID).leaseOwner)
    }

    func testLibraryAnalysisListJobsUpgradesActiveRetryBudgetAndExposesAttempts() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 95, uti: .png))
        let asset = try env.seedAsset(
            relativePath: "retry-budget.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET attempts = 3, max_attempts = 5 WHERE id = ?",
                arguments: [enqueued.jobID.uuidString.lowercased()]
            )
        }

        let summary = try XCTUnwrap(analysis.listJobs().first)

        XCTAssertEqual(summary.attempts, 3)
        XCTAssertEqual(summary.maxAttempts, 10)
        XCTAssertEqual(summary.sourceNames, ["Fixture"])
        XCTAssertEqual(try queue.fetchJob(id: enqueued.jobID).maxAttempts, 10)
    }

    func testLibraryAnalysisEnqueuePreservesPausedJob() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 92, uti: .png))
        let left = try env.seedAsset(relativePath: "supersede-left.png", contents: bytes, mediaType: "public.png")
        let right = try env.seedAsset(relativePath: "supersede-right.png", contents: bytes, mediaType: "public.png")
        let seed = try env.seedAsset(
            relativePath: "supersede-seed.png",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 93, uti: .png)),
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        let first = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [left.assetID, right.assetID],
            seedAssetIDs: []
        )
        XCTAssertEqual(try analysis.pause(jobID: first.jobID).state, .paused)

        let second = try analysis.enqueue(
            mode: .seeds,
            assetIDs: [left.assetID, right.assetID, seed.assetID],
            seedAssetIDs: [seed.assetID]
        )
        XCTAssertNotEqual(second.jobID, first.jobID)
        XCTAssertEqual(second.state, .pending)
        XCTAssertEqual(second.seedAssetIDs, [seed.assetID])
        XCTAssertEqual(try analysis.snapshot(jobID: first.jobID).state, .paused)

        let jobs = try analysis.listJobs()
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Set(jobs.map(\.jobID)), Set([first.jobID, second.jobID]))
        XCTAssertEqual(jobs.first(where: { $0.jobID == second.jobID })?.seedCount, 1)
        XCTAssertEqual(jobs.first(where: { $0.jobID == first.jobID })?.memberCount, 2)

        try analysis.delete(jobID: first.jobID)
        let remaining = try analysis.listJobs()
        XCTAssertEqual(remaining.map(\.jobID), [second.jobID])
        XCTAssertThrowsError(try analysis.snapshot(jobID: first.jobID))
    }

    func testLibraryAnalysisClusteringHeartbeatCompletesBeyondOriginalLease() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 96, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "heartbeat.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let clock = MutableJobClock(nowMs: JobTestSupport.baseTimeMs)
        let scanner = LeaseAdvancingSlimmingScanner(
            clock: clock,
            heartbeatAtMs: JobTestSupport.baseTimeMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs / 2,
            finishAtMs: JobTestSupport.baseTimeMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs / 5
        )
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(
                delayMs: JobTestSupport.retryDelayMs
            )
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        scanner.afterProgress = {
            let running = try analysis.snapshot(jobID: enqueued.jobID)
            XCTAssertEqual(running.state, .running)
            XCTAssertEqual(running.scanProgress?.phase, .loadingFeaturePrints)
            XCTAssertEqual(running.scanProgress?.completed, 1)
            XCTAssertEqual(running.scanProgress?.total, 2)
            XCTAssertEqual(running.scanProgress?.completionPass, 1)
            let summary = try XCTUnwrap(analysis.listJobs().first)
            XCTAssertEqual(summary.scanProgress, running.scanProgress)
            let activity = try XCTUnwrap(queue.fetchActivityItems().first)
            XCTAssertEqual(JobActivityPresentation.progressText(for: activity), running.scanProgress?.caption)
        }
        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.progress.completed, finished.progress.total)
    }

    func testLibraryAnalysisClusteringRenewsLeaseWithoutProgressCallbacks() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 98, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "callback-free-heartbeat.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let clock = SystemJobClock()
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: JobTestSupport.retryDelayMs)
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: CallbackFreeBlockingSlimmingScanner(delay: 0.65),
            clock: clock,
            leaseDurationMs: 300
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.progress.completed, finished.progress.total)
    }
}

private final class LeaseAdvancingSlimmingScanner: LibrarySlimmingScanPort,
    @unchecked Sendable
{
    var afterProgress: (() throws -> Void)?
    private let clock: MutableJobClock
    private let heartbeatAtMs: Int64
    private let finishAtMs: Int64

    init(clock: MutableJobClock, heartbeatAtMs: Int64, finishAtMs: Int64) {
        self.clock = clock
        self.heartbeatAtMs = heartbeatAtMs
        self.finishAtMs = finishAtMs
    }

    func scan(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        clock.setNowMs(heartbeatAtMs)
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .loadingFeaturePrints,
                completed: 1,
                total: 2
            )
        )
        try afterProgress?()
        clock.setNowMs(finishAtMs)
        return LibrarySlimmingScanResult(
            clusters: [],
            pendingAnalysisAssetIDs: [],
            analyzedAssetCount: assetIDs.count,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
    }

    func scanCatalog(
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: [], onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        _ = seedAssetIDs
        return try scan(assetIDs: universeAssetIDs, onProgress: onProgress)
    }
}

private struct CallbackFreeBlockingSlimmingScanner: LibrarySlimmingScanPort {
    let delay: TimeInterval

    func scan(
        assetIDs: [UUID],
        onProgress _: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        Thread.sleep(forTimeInterval: delay)
        return LibrarySlimmingScanResult(
            clusters: [],
            pendingAnalysisAssetIDs: [],
            analyzedAssetCount: assetIDs.count,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
    }

    func scanCatalog(
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: [], onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs _: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: universeAssetIDs, onProgress: onProgress)
    }
}

private final class SimilarityDownloadedPreviewCacheStub: DownloadedPreviewCachePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let loaded: Data?
    private var storedLoadCount = 0
    private var storedStoreCount = 0

    init(loaded: Data?) {
        self.loaded = loaded
    }

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    var storeCount: Int {
        lock.withLock { storedStoreCount }
    }

    func loadDownloadedPreview(assetID: UUID) throws -> Data? {
        _ = assetID
        lock.withLock { storedLoadCount += 1 }
        return loaded
    }

    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data {
        _ = assetID
        lock.withLock { storedStoreCount += 1 }
        return sourceBytes
    }
}

enum SimilarityTestSupport {
    struct SeededAsset {
        let assetID: UUID
        let fileURL: URL
    }

    final class Environment {
        let root: URL
        let sourceRoot: URL
        let database: CatalogDatabase
        let bookmark: Data
        let sourceID: UUID
        private var didInsertSource = false

        init(label: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImageAllSimilarity-\(label)-\(UUID().uuidString)", isDirectory: true)
            sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
            let databaseURL = root.appendingPathComponent("catalog.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            database = try CatalogDatabase.open(at: databaseURL)
            sourceID = UUID()
            bookmark = sourceRoot.path.data(using: .utf8) ?? Data()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func makeCompletionService(
            photosOriginals: (any PhotosOriginalContentPort)? = nil,
            photosFeatureImages: (any PhotosFeaturePrintImagePort)? = nil,
            downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
            retainsPhotosOriginals: Bool = true,
            videoPosterGenerator: any DerivedVideoPosterGenerating =
                AVFoundationDerivedVideoPosterGenerator()
        ) -> FingerprintCompletionService {
            let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
                rootByBookmark: [bookmark: sourceRoot]
            )
            let sourceAccess = FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            )
            return FingerprintCompletionService(
                database: database,
                sourceAccess: sourceAccess,
                photosOriginals: photosOriginals,
                photosOriginalCache: PhotosOriginalCacheService(
                    database: database,
                    configuredRootURL: retainsPhotosOriginals
                        ? root.appendingPathComponent("Photos Originals", isDirectory: true)
                        : nil,
                    legacyRootURLs: [],
                    accessLease: nil,
                    clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
                ),
                photosFeatureImages: photosFeatureImages,
                downloadedPreviews: downloadedPreviews,
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
                videoPosterGenerator: videoPosterGenerator
            )
        }

        @discardableResult
        func seedAsset(
            relativePath: String,
            contents: Data,
            mediaType: String = "public.jpeg",
            mediaCreatedAtMs: Int64? = nil,
            mediaKind: MediaKind = .image,
            durationMs: Int64? = nil
        ) throws -> SeededAsset {
            let assetID = UUID()
            let fileURL = sourceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL)
            let reader = FoundationFolderFileResourceReader()
            let sizeBytes = reader.fileSizeBytes(for: fileURL) ?? 0
            let modifiedAtNs = reader.modifiedAtNs(for: fileURL) ?? 0
            let resourceID = reader.resourceIdentifier(for: fileURL)
            let fileName = RelativePathRules.fileName(from: relativePath) ?? fileURL.lastPathComponent

            try database.pool.write { db in
                if !didInsertSource {
                    try db.execute(
                        sql: """
                        INSERT INTO source (
                            id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                            state, created_at_ms, updated_at_ms
                        ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                        """,
                        arguments: [
                            sourceID.uuidString.lowercased(),
                            bookmark,
                            FolderReconcileTestSupport.baseTimeMs,
                            FolderReconcileTestSupport.baseTimeMs,
                        ]
                    )
                    didInsertSource = true
                }
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, media_created_at_ms, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name, media_kind, duration_ms
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, ?, 1, 'available', ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        relativePath,
                        mediaType,
                        mediaCreatedAtMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        fileName,
                        mediaKind.rawValue,
                        durationMs,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                    VALUES (?, ?, ?, ?, NULL)
                    """,
                    arguments: [assetID.uuidString.lowercased(), sizeBytes, modifiedAtNs, resourceID]
                )
            }
            return SeededAsset(assetID: assetID, fileURL: fileURL)
        }

        func seedPhotosAsset(
            mediaType: String = "public.jpeg",
            mediaKind: MediaKind = .image,
            durationMs: Int64? = nil
        ) throws -> UUID {
            let photosSourceID = UUID()
            let assetID = UUID()
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'photos', 'Photos', NULL, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        photosSourceID.uuidString.lowercased(),
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name,
                        media_kind, duration_ms
                    ) VALUES (?, ?, 'photos', NULL, ?, 'current', ?, 1, 'available', ?, ?, NULL, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        photosSourceID.uuidString.lowercased(),
                        "LOCAL-\(assetID.uuidString.lowercased())",
                        mediaType,
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        mediaKind.rawValue,
                        durationMs,
                    ]
                )
            }
            return assetID
        }

        func sourceFileSnapshot(for fileURL: URL) throws -> Data {
            try Data(contentsOf: fileURL)
        }
    }

    static func patternedImageData(
        seed: UInt8,
        uti: UTType,
        width: Int = 64,
        height: Int = 64,
        quality: Double? = nil
    ) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let v = UInt8((Int(seed) &* 17 &+ x &* 3 &+ y &* 5) & 0xFF)
                pixels[idx] = v
                pixels[idx + 1] = UInt8((Int(seed) &* 29 &+ x &* 7) & 0xFF)
                pixels[idx + 2] = UInt8((Int(seed) &* 13 &+ y &* 11) & 0xFF)
                pixels[idx + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func solidImageData(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        uti: UTType,
        width: Int = 64,
        height: Int = 64
    ) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private struct SimilarityVideoPosterStub: DerivedVideoPosterGenerating {
    func makePosterBytes(
        sourceFileDescriptorURL: URL,
        mediaType _: String,
        durationMs _: Int64,
        maximumPixelSize _: Int
    ) throws -> Data {
        let source = try Data(contentsOf: sourceFileDescriptorURL)
        if source.first == 1 {
            return try XCTUnwrap(
                SimilarityTestSupport.patternedImageData(seed: 101, uti: .png)
            )
        }
        if source.first == 2 {
            return try XCTUnwrap(
                SimilarityTestSupport.patternedImageData(seed: 180, uti: .png)
            )
        }
        return try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 240, uti: .png)
        )
    }
}

private final class SimilarityPhotosOriginalStub: PhotosOriginalContentPort, @unchecked Sendable {
    private let lock = NSLock()
    var bytes: Data?
    let error: PhotosLibraryError?
    private var storedRequestCount = 0

    init(bytes: Data? = nil, error: PhotosLibraryError? = nil) {
        self.bytes = bytes
        self.error = error
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func requestOriginalImageData(localIdentifier: String) throws -> Data {
        _ = localIdentifier
        return try lock.withLock {
            storedRequestCount += 1
            if let error {
                throw error
            }
            guard let bytes else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return bytes
        }
    }
}

private final class SimilarityPhotosFeatureImageStub: PhotosFeaturePrintImagePort, @unchecked Sendable {
    private let lock = NSLock()
    let bytes: Data?
    let error: PhotosLibraryError?
    private var storedRequestCount = 0

    init(bytes: Data? = nil, error: PhotosLibraryError? = nil) {
        self.bytes = bytes
        self.error = error
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func requestLocalFeatureImage(localIdentifier: String) throws -> Data {
        _ = localIdentifier
        return try lock.withLock {
            storedRequestCount += 1
            if let error {
                throw error
            }
            guard let bytes else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return bytes
        }
    }
}


/// Test-only hook requests control after the real service has consumed a chunk.
private final class ExplicitVideoAnalysisTestCompletion: FingerprintCompletionPort, @unchecked Sendable {
    let base: FingerprintCompletionService
    var onChunk: ((Int64, Int64) throws -> Void)?
    init(base: FingerprintCompletionService) { self.base = base }
    func validatePrerequisites(assetIDs: [UUID]) throws { try base.validatePrerequisites(assetIDs: assetIDs) }
    func completeAsset(assetID: UUID) throws -> AssetContentFingerprint { try base.completeAsset(assetID: assetID) }
    func completeFolderAsset(assetID: UUID) throws -> AssetContentFingerprint { try base.completeFolderAsset(assetID: assetID) }
    func completePendingAssets(limit: Int) throws -> [AssetContentFingerprint] { try base.completePendingAssets(limit: limit) }
    func completePendingFolderAssets(limit: Int) throws -> [AssetContentFingerprint] { try base.completePendingFolderAssets(limit: limit) }
    func completeExplicitAnalysisAsset(assetID: UUID, checkCancellation: () throws -> Void,
        onByteProgress: (Int64, Int64) -> Void) throws {
        var callbackError: Error?
        try base.completeExplicitAnalysisAsset(assetID: assetID, checkCancellation: {
            if let callbackError { throw callbackError }
            try checkCancellation()
        }, onByteProgress: { done, total in
            onByteProgress(done, total)
            do { try self.onChunk?(done, total) } catch { callbackError = error }
        })
    }
}

private final class SyntheticPhotosVideoDigestReader: PhotosOriginalVideoContentPort, @unchecked Sendable {
    let bytes: Data
    var cloudIDs = Set<String>()
    var editedIDs = Set<String>()
    var calls = 0
    var onCompletedRead: (() throws -> Void)?
    init(bytes: Data) { self.bytes = bytes }
    func requestLocalOriginalVideoDigest(localIdentifier: String, checkCancellation: () throws -> Void,
        onByteProgress: (Int64, Int64) -> Void) throws -> PhotosOriginalVideoDigest {
        calls += 1
        try checkCancellation()
        if cloudIDs.contains(localIdentifier) { throw PhotosLibraryError.cloudOnly }
        let state = PhotosOriginalVideoStreamState()
        for offset in stride(from: 0, to: bytes.count, by: 256 * 1024) {
            try checkCancellation()
            state.receive(bytes.subdata(in: offset..<min(offset + 256 * 1024, bytes.count)))
            onByteProgress(state.snapshot().byteCount, 0)
        }
        state.complete(nil)
        try onCompletedRead?()
        let result = try state.finalDigest()
        return PhotosOriginalVideoDigest(sha256: result.sha256, byteCount: result.byteCount,
            resourceIdentity: "synthetic-original-\(localIdentifier)", hasAdjustments: editedIDs.contains(localIdentifier))
    }
}

private final class SyntheticVideoAnalysisSource: PhotosVideoAnalysisSourcePort, @unchecked Sendable {
    let url: URL
    var resourceIdentity = "synthetic-original"
    var failure: Error?
    init(url: URL) { self.url = url }
    func withLocalVideoAnalysisSource<T>(localIdentifier: String,
        checkCancellation: () throws -> Void, perform: (PhotosLocalVideoAnalysisSource) throws -> T) throws -> T {
        try checkCancellation()
        if let failure { throw failure }
        let before = resourceIdentity
        let value = try perform(PhotosLocalVideoAnalysisSource(url: url, durationMs: 1_000,
            mediaType: "public.mpeg-4", resourceIdentity: before))
        try checkCancellation()
        guard resourceIdentity == before else { throw FingerprintCompletionError.sourceChanged }
        return value
    }
}
