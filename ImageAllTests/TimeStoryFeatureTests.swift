import AppKit
@preconcurrency import AVFoundation
import GRDB
@testable import ImageAll
import XCTest

final class TimeStoryFeatureTests: XCTestCase {
    func testCandidateProviderReadsEveryPageAndFreezesStableSnapshot() throws {
        let databaseURL = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: databaseURL)
        let repository = CatalogRepository(database: database)
        let firstSource = UUID()
        let secondSource = UUID()
        let firstID = UUID(uuidString: "01000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "01000000-0000-0000-0000-000000000002")!
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: firstSource,
            assetID: firstID
        )
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: secondSource,
            assetID: secondID
        )
        let first = projection(firstID, sourceID: firstSource, time: timestamp(2019, 1, 1))
        let second = projection(secondID, sourceID: secondSource, time: timestamp(2025, 1, 1))
        let query = PagingStoryQuery(first: first, second: second)
        let tag = TagListItem(id: UUID(), displayName: "任意主体", state: .active)

        let snapshot = try TimeStoryCandidateProvider(database: database, query: query)
            .snapshot(tag: tag, nowMs: 123)

        XCTAssertEqual(query.requests.count, 2)
        XCTAssertTrue(query.requests.allSatisfy { $0.limit == 500 && $0.sort == .embeddedTimeOldest })
        XCTAssertEqual(query.requests.first?.filter.tagDecisionFilters, [
            TagDecisionFilter(tagID: tag.id, decision: .accepted),
        ])
        XCTAssertEqual(snapshot.candidates.map(\.assetID), [firstID, secondID])
        XCTAssertEqual(snapshot.candidates.map(\.locationState), [.unconfirmed, .unconfirmed])
        XCTAssertTrue(snapshot.id.hasPrefix("sha256:"))
    }

    func testPlannerPreservesSparseEarlyEraABAAndUnknownTimeBoundary() throws {
        let earlyNoGPS = candidate(
            "00000000-0000-0000-0000-000000000001",
            time: timestamp(2018, 1, 1),
            favorite: true,
            place: nil,
            locationState: .absent,
            cluster: "growth-pose"
        )
        let earlyA = candidate(
            "00000000-0000-0000-0000-000000000002",
            time: timestamp(2018, 2, 1),
            place: "上海"
        )
        let middleB = candidate(
            "00000000-0000-0000-0000-000000000003",
            time: timestamp(2021, 6, 1),
            place: "杭州"
        )
        let recentA = candidate(
            "00000000-0000-0000-0000-000000000004",
            time: timestamp(2025, 1, 1),
            place: "上海",
            cluster: "growth-pose"
        )
        let recentFlood = (5 ... 35).map { index in
            candidate(
                String(format: "00000000-0000-0000-0000-%012d", index),
                time: timestamp(2025, 1, min(28, index)),
                place: "上海",
                cluster: index < 12 ? "recent-burst" : nil
            )
        }
        let unknown = candidate(
            "00000000-0000-0000-0000-000000000099",
            time: nil,
            place: "北京"
        )
        let snapshot = makeSnapshot(
            [earlyNoGPS, earlyA, middleB, recentA] + recentFlood + [unknown]
        )

        let project = try TimeStoryPlanner().makeProject(snapshot: snapshot, nowMs: 10)

        XCTAssertLessThanOrEqual(project.shots.count, TimeStoryConstants.maximumShots)
        XCTAssertTrue(project.shots.contains { $0.assetID == earlyNoGPS.assetID }, "稀疏早期无 GPS 收藏照必须保留")
        XCTAssertTrue(project.shots.contains { $0.assetID == middleB.assetID })
        XCTAssertTrue(project.shots.contains { $0.assetID == recentA.assetID })
        XCTAssertFalse(project.shots.contains { $0.assetID == unknown.assetID })
        XCTAssertEqual(project.readiness.unknownTimeCount, 1)
        XCTAssertEqual(project.readiness.noLocationCount, 1)
        let namedChapterVisits = project.chapters.map(\.title).filter { ["上海", "杭州"].contains($0) }
        XCTAssertEqual(namedChapterVisits, ["上海", "杭州", "上海"])
        XCTAssertEqual(
            Set(project.shots.filter { [earlyNoGPS.assetID, recentA.assetID].contains($0.assetID) }.map(\.assetID)),
            Set([earlyNoGPS.assetID, recentA.assetID]),
            "跨时期相似画面不得被统一去掉"
        )
    }

    func testTimelineStateRepresentsTheTransitionOverlap() throws {
        let first = candidate("02000000-0000-0000-0000-000000000001", time: timestamp(2020, 1, 1))
        let second = candidate("02000000-0000-0000-0000-000000000002", time: timestamp(2024, 1, 1))
        let shots = [makeShot(asset: first, index: 0), makeShot(asset: second, index: 1)]
        let transitionStart = shots[0].durationSeconds - TimeStoryConstants.transitionDurationSeconds
        let overlapping = try XCTUnwrap(TimeStoryTimeline.state(
            at: transitionStart + 0.1,
            shots: shots,
            transitionSeconds: TimeStoryConstants.transitionDurationSeconds
        ))

        XCTAssertEqual(overlapping.current.id, shots[0].id)
        XCTAssertEqual(overlapping.next?.id, shots[1].id)
        XCTAssertGreaterThan(overlapping.blend, 0)
        XCTAssertLessThan(overlapping.blend, 1)

        let afterTransition = try XCTUnwrap(TimeStoryTimeline.state(
            at: shots[0].durationSeconds + 0.01,
            shots: shots,
            transitionSeconds: TimeStoryConstants.transitionDurationSeconds
        ))
        XCTAssertEqual(afterTransition.current.id, shots[1].id)
        XCTAssertNil(afterTransition.next)
    }

    func testRegeneratePreservesLocksExclusionsAndExplicitEdits() throws {
        let candidates = (1 ... 8).map { index in
            candidate(
                String(format: "10000000-0000-0000-0000-%012d", index),
                time: timestamp(2018 + index, 1, 1),
                favorite: index == 3,
                place: index < 4 ? "A 城" : "B 城"
            )
        }
        let planner = TimeStoryPlanner()
        let snapshot = makeSnapshot(candidates)
        var original = try planner.makeProject(snapshot: snapshot, nowMs: 1)
        let lockedID = try XCTUnwrap(original.shots.first?.id)
        original.shots[0].isLocked = true
        original.shots[0].durationSeconds = 7.5
        original.shots[0].isUserEdited = true
        let excluded = original.shots[1].assetID
        original.excludedAssetIDs.insert(excluded)
        original.shots.remove(at: 1)
        let editedChapterID = try XCTUnwrap(original.chapters.first?.id)
        original.chapters[0].title = "我的早期章节"
        original.chapters[0].isUserEdited = true

        let regenerated = try planner.makeProject(snapshot: snapshot, nowMs: 2, existing: original)

        let locked = try XCTUnwrap(regenerated.shots.first(where: { $0.id == lockedID }))
        XCTAssertTrue(locked.isLocked)
        XCTAssertEqual(locked.durationSeconds, 7.5)
        XCTAssertFalse(regenerated.shots.contains { $0.assetID == excluded })
        XCTAssertEqual(
            regenerated.chapters.first(where: { $0.id == editedChapterID })?.title,
            "我的早期章节"
        )
    }

    func testProjectStoreAtomicallySavesAndReopensEditableProject() throws {
        let root = try temporaryDirectory("story-store")
        let store = TimeStoryProjectStore(applicationSupportDirectory: root)
        var project = try TimeStoryPlanner().makeProject(
            snapshot: makeSnapshot([
                candidate("20000000-0000-0000-0000-000000000001", time: timestamp(2020, 1, 1), place: "苏州"),
                candidate("20000000-0000-0000-0000-000000000002", time: timestamp(2024, 1, 1), place: "南京"),
            ]),
            nowMs: 1
        )
        project.chapters[0].title = "用户标题"
        project.chapters[0].isUserEdited = true
        project.shots[0].durationSeconds = 5
        project.shots[0].isUserEdited = true

        try store.save(project)
        let reopened = try store.load(project.id)

        XCTAssertEqual(reopened, project)
        XCTAssertEqual(try store.list().map(\.id), [project.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.rootDirectory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".imageallstory") }.count, 1)
        XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") })
    }

    func testMediaValidatorLocatesMissingAndChangedShots() throws {
        let databaseURL = try makeTempDatabaseURL()
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        let database = CatalogDatabase(pool: pool)
        try database.migrate()
        let sourceID = UUID()
        let existing = candidate("30000000-0000-0000-0000-000000000001", time: timestamp(2020, 1, 1))
        let missing = candidate("30000000-0000-0000-0000-000000000002", time: timestamp(2021, 1, 1))
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: database),
            sourceID: sourceID,
            assetID: existing.assetID
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 2 WHERE id = ?",
                arguments: [existing.assetID.uuidString.lowercased()]
            )
        }
        var project = try TimeStoryPlanner().makeProject(
            snapshot: makeSnapshot([existing, missing]),
            nowMs: 1
        )
        // Ensure both fixture assets are represented regardless of short-story ordering.
        project.shots = [
            makeShot(asset: existing, index: 0),
            makeShot(asset: missing, index: 1),
        ]

        let issues = try TimeStoryMediaValidator(database: database).validate(project)

        XCTAssertEqual(issues.map(\.shotIndex), [1, 2])
        XCTAssertEqual(issues.map(\.kind), [.versionChanged, .missing])
    }

    func testRendererExportsPlayableMP4WithAndWithoutMusic() async throws {
        let root = try temporaryDirectory("story-render")
        let first = UUID()
        let second = UUID()
        let loader = FixtureStoryMediaLoader(images: [
            first: try pngData(color: .systemRed, portrait: false),
            second: try pngData(color: .systemBlue, portrait: true),
        ])
        let renderer = AVFoundationTimeStoryRenderer(
            media: loader,
            temporaryDirectory: root.appendingPathComponent("render-tmp", isDirectory: true)
        )
        var project = try TimeStoryPlanner().makeProject(
            snapshot: makeSnapshot([
                candidate(first.uuidString, time: timestamp(2020, 1, 1), place: "上海"),
                candidate(second.uuidString, time: timestamp(2024, 1, 1), place: "杭州"),
            ]),
            nowMs: 1
        )
        project.chapters[0].title = "用户编辑的章节"
        project.chapters[0].isUserEdited = true
        for index in project.shots.indices {
            project.shots[index].durationSeconds = 1.5
            project.shots[index].isUserEdited = true
        }
        let store = TimeStoryProjectStore(applicationSupportDirectory: root.appendingPathComponent("app-support"))
        try store.save(project)
        project = try store.load(project.id)
        XCTAssertEqual(project.chapters[0].title, "用户编辑的章节")
        let silent = root.appendingPathComponent("silent.mp4")
        try await renderer.render(project: project, destinationURL: silent) { _ in }
        try await assertPlayableVideo(silent, expectsAudio: false, expectedDuration: project.timelineDurationSeconds)

        let music = root.appendingPathComponent("tone.wav")
        try writeSineWave(to: music, seconds: 1)
        project.music = TimeStoryMusicSelection(
            displayName: "tone.wav",
            filePath: music.path,
            securityScopedBookmark: nil
        )
        let musical = root.appendingPathComponent("musical.mp4")
        try await renderer.render(project: project, destinationURL: musical) { _ in }
        try await assertPlayableVideo(musical, expectsAudio: true, expectedDuration: project.timelineDurationSeconds)
        try retainEvidenceIfRequested(silent: silent, musical: musical)
    }

    func testCancelledExportDoesNotReplaceExistingFile() async throws {
        let root = try temporaryDirectory("story-cancel")
        let first = UUID()
        let second = UUID()
        let loader = FixtureStoryMediaLoader(images: [
            first: try pngData(color: .orange, portrait: false),
            second: try pngData(color: .purple, portrait: false),
        ])
        let renderer = AVFoundationTimeStoryRenderer(
            media: loader,
            temporaryDirectory: root.appendingPathComponent("render-tmp", isDirectory: true)
        )
        var project = renderProject(first: first, second: second)
        project.shots[0].durationSeconds = 12
        project.shots[1].durationSeconds = 12
        let cancellableProject = project
        let destination = root.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing-good-export".utf8)
        try sentinel.write(to: destination)

        let task = Task {
            try await renderer.render(project: cancellableProject, destinationURL: destination) { _ in }
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled render unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(cancellableProject.shots.count, 2)
    }

    private func makeSnapshot(_ candidates: [TimeStoryCandidate]) -> TimeStoryCandidateSnapshot {
        TimeStoryCandidateSnapshot(
            id: "fixture-v1",
            createdAtMs: 1,
            tagID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            tagDisplayName: "测试主体",
            candidates: candidates
        )
    }

    private func candidate(
        _ rawID: String,
        time: Int64?,
        favorite: Bool = false,
        place: String? = nil,
        locationState: TimeStoryLocationState? = nil,
        cluster: String? = nil
    ) -> TimeStoryCandidate {
        TimeStoryCandidate(
            assetID: UUID(uuidString: rawID)!,
            contentRevision: 1,
            sourceID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            fileName: rawID + ".png",
            mediaCreatedAtMs: time,
            width: 4_000,
            height: 3_000,
            availability: .available,
            isFavorite: favorite,
            locationState: locationState ?? (place == nil ? .unconfirmed : .named),
            placeName: place,
            locationSource: place == nil ? nil : "placeTag",
            similarityClusterID: cluster,
            similarityState: cluster == nil ? .unavailable : .ready
        )
    }

    private func projection(_ assetID: UUID, sourceID: UUID, time: Int64?) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: assetID,
            sourceID: sourceID,
            sourceDisplayName: "Fixture",
            sourceState: .active,
            relativePath: "album/\(assetID.uuidString).jpg",
            fileName: "\(assetID.uuidString).jpg",
            mediaType: "public.jpeg",
            mediaCreatedAtMs: time,
            mediaModifiedAtMs: time,
            width: 4_000,
            height: 3_000,
            availability: .available,
            contentRevision: 1,
            acceptedTagCount: 1,
            rejectedTagCount: 0
        )
    }

    private func timestamp(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return Int64(components.date!.timeIntervalSince1970 * 1_000)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-TimeStoryTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeShot(asset: TimeStoryCandidate, index: Int) -> TimeStoryShot {
        TimeStoryShot(
            id: UUID(),
            assetID: asset.assetID,
            contentRevision: asset.contentRevision,
            chapterID: UUID(),
            caption: "镜头 \(index + 1)",
            durationSeconds: 1.5,
            presentationMode: .fullFrameWithBackground,
            reasons: ["测试"],
            isLocked: false,
            isUserEdited: false
        )
    }

    private func renderProject(first: UUID, second: UUID) -> TimeStoryProject {
        let chapterID = UUID()
        let firstCandidate = candidate(first.uuidString, time: timestamp(2020, 1, 1))
        let secondCandidate = candidate(second.uuidString, time: timestamp(2024, 1, 1))
        let shots = [makeShot(asset: firstCandidate, index: 0), makeShot(asset: secondCandidate, index: 1)]
        return TimeStoryProject(
            schemaVersion: 1,
            id: UUID(),
            createdAtMs: 1,
            updatedAtMs: 1,
            subjectTagID: UUID(),
            subjectTagDisplayName: "测试主体",
            templateVersion: TimeStoryConstants.templateVersion,
            strategyVersion: TimeStoryConstants.strategyVersion,
            title: "测试主体 · 成长与足迹",
            candidateSnapshot: makeSnapshot([firstCandidate, secondCandidate]),
            readiness: TimeStoryReadinessSummary(
                matchingCount: 2,
                reliableTimeStartMs: firstCandidate.mediaCreatedAtMs,
                reliableTimeEndMs: secondCandidate.mediaCreatedAtMs,
                unknownTimeCount: 0,
                namedPlaceCount: 0,
                coordinateOnlyCount: 0,
                noLocationCount: 0,
                locationMetadataUnconfirmedCount: 2,
                unavailableCount: 0,
                similarityFilteringState: .unavailable,
                selectionTradeoff: nil
            ),
            chapters: [TimeStoryChapter(
                id: chapterID,
                title: "成长片段",
                shotIDs: shots.map(\.id),
                isUserEdited: false
            )],
            shots: shots.map {
                var shot = $0
                shot.chapterID = chapterID
                return shot
            },
            excludedAssetIDs: [],
            music: nil
        )
    }

    private func pngData(color: NSColor, portrait: Bool) throws -> Data {
        let size = portrait ? NSSize(width: 600, height: 900) : NSSize(width: 1_200, height: 700)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.35, y: size.height * 0.3, width: 120, height: 120)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("Unable to create synthetic PNG") }
        return data
    }

    private func assertPlayableVideo(
        _ url: URL,
        expectsAudio: Bool,
        expectedDuration: Double
    ) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, expectedDuration, accuracy: 0.12)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await video.load(.naturalSize)
        let preferredTransform = try await video.load(.preferredTransform)
        let size = naturalSize.applying(preferredTransform)
        XCTAssertEqual(Int(abs(size.width)), TimeStoryConstants.outputWidth)
        XCTAssertEqual(Int(abs(size.height)), TimeStoryConstants.outputHeight)
        let frameRate = try await video.load(.nominalFrameRate)
        XCTAssertEqual(frameRate, 30, accuracy: 0.1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.isEmpty, !expectsAudio)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        for fraction in [0.03, 0.5, 0.97] {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            XCTAssertEqual(image.width, TimeStoryConstants.outputWidth)
            XCTAssertEqual(image.height, TimeStoryConstants.outputHeight)
            XCTAssertTrue(hasVisiblePixels(image), "sampled frame must not be black")
        }
    }

    private func hasVisiblePixels(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return false }
        let length = CFDataGetLength(data)
        let stride = max(4, length / 2_000)
        var total = 0
        var samples = 0
        var index = 0
        while index + 2 < length {
            total += Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])
            samples += 1
            index += stride
        }
        return samples > 0 && total / samples > 20
    }

    private func writeSineWave(to url: URL, seconds: Int) throws {
        let sampleRate = 44_100
        let sampleCount = sampleRate * seconds
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0 ..< sampleCount {
            let value = Int16(sin(Double(index) * 2 * .pi * 440 / Double(sampleRate)) * 4_000)
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        var wave = Data()
        wave.append("RIFF".data(using: .ascii)!)
        appendUInt32(UInt32(36 + pcm.count), to: &wave)
        wave.append("WAVEfmt ".data(using: .ascii)!)
        appendUInt32(16, to: &wave)
        appendUInt16(1, to: &wave)
        appendUInt16(1, to: &wave)
        appendUInt32(UInt32(sampleRate), to: &wave)
        appendUInt32(UInt32(sampleRate * 2), to: &wave)
        appendUInt16(2, to: &wave)
        appendUInt16(16, to: &wave)
        wave.append("data".data(using: .ascii)!)
        appendUInt32(UInt32(pcm.count), to: &wave)
        wave.append(pcm)
        try wave.write(to: url, options: .atomic)
    }

    private func retainEvidenceIfRequested(silent: URL, musical: URL) throws {
        let marker = URL(fileURLWithPath: "/tmp/ImageAll-TimeStory-Evidence-Request")
        let rawDirectory = ProcessInfo.processInfo.environment["IMAGEALL_TIME_STORY_EVIDENCE_DIR"]
            ?? (try? String(contentsOf: marker, encoding: .utf8))
        guard let rawDirectory = rawDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDirectory.isEmpty
        else { return }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (source, name) in [(silent, "synthetic-silent.mp4"), (musical, "synthetic-with-music.mp4")] {
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

private final class PagingStoryQuery: AssetCatalogQueryPort, @unchecked Sendable {
    private let lock = NSLock()
    private let first: AssetGridItemProjection
    private let second: AssetGridItemProjection
    private(set) var requests: [AssetPageRequest] = []

    init(first: AssetGridItemProjection, second: AssetGridItemProjection) {
        self.first = first
        self.second = second
    }

    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult {
        lock.withLock { requests.append(request) }
        if request.cursor == nil {
            return AssetPageResult(
                items: [first],
                nextCursor: AssetPageCursor(
                    sort: .embeddedTimeOldest,
                    payload: .embeddedTimeSort(
                        timeEmptyMarker: 0,
                        embeddedTimeMs: first.mediaCreatedAtMs,
                        assetID: first.assetID
                    )
                )
            )
        }
        return AssetPageResult(items: [second], nextCursor: nil)
    }

    func fetchSourceFolders(sourceID: UUID) throws -> [LibrarySourceFolder] { throw FixtureError.unused }
    func fetchSourceFolderPage(
        sourceID: UUID,
        parentRelativePath: String?,
        offset: Int,
        limit: Int
    ) throws -> LibrarySourceFolderPage { throw FixtureError.unused }
    func sourceFolderExists(_ scope: AssetFolderScope) throws -> Bool { throw FixtureError.unused }
    func searchSourceFolders(
        sourceID: UUID,
        text: String,
        limit: Int
    ) throws -> LibrarySourceFolderPage { throw FixtureError.unused }
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot { throw FixtureError.unused }
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail { throw FixtureError.unused }
    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int { throw FixtureError.unused }

    private enum FixtureError: Error { case unused }
}

private struct FixtureStoryMediaLoader: TimeStoryMediaLoading {
    let images: [UUID: Data]

    func loadStoryImage(assetID: UUID) async throws -> Data {
        guard let data = images[assetID] else { throw TimeStoryError.noCandidates }
        return data
    }
}
