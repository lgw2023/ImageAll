import AppKit
@preconcurrency import AVFoundation
import CryptoKit
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
        let project = renderProject(first: first.assetID, second: second.assetID)
        let timeline = try TimeStoryTimeline.normalize(project: project)
        XCTAssertEqual(timeline.fps, 30)
        XCTAssertEqual(timeline.segments.map(\.kind), [.projectTitle, .chapterTitle, .photo, .photo])
        XCTAssertEqual(timeline.segments.map(\.durationFrames), [90, 60, 45, 45])
        XCTAssertEqual(timeline.segments.map(\.transitionInFrames), [0, 14, 14, 14])
        XCTAssertEqual(timeline.segments.map(\.startFrame), [0, 76, 122, 153])
        XCTAssertEqual(timeline.totalFrames, 198)

        let overlapping = try XCTUnwrap(timeline.state(atFrame: 156))

        XCTAssertEqual(overlapping.current.shotID, project.shots[0].id)
        XCTAssertEqual(overlapping.next?.shotID, project.shots[1].id)
        XCTAssertGreaterThan(overlapping.blend, 0)
        XCTAssertLessThan(overlapping.blend, 1)

        let afterTransition = try XCTUnwrap(timeline.state(atFrame: 167))
        XCTAssertEqual(afterTransition.current.shotID, project.shots[1].id)
        XCTAssertNil(afterTransition.next)
    }

    func testTimelineQuantizesLegacySecondsOnceAndBoundsShortTransitions() throws {
        let first = UUID()
        let second = UUID()
        var project = renderProject(first: first, second: second)
        project.shots[0].durationSeconds = 1.0 / 30.0
        project.shots[1].durationSeconds = 0.1

        let timeline = try TimeStoryTimeline.normalize(project: project)
        let photos = timeline.segments.filter { $0.kind == .photo }

        XCTAssertEqual(photos.map(\.durationFrames), [1, 3])
        XCTAssertEqual(photos[0].transitionInFrames, 0, "one-frame photo cannot overlap its predecessor")
        XCTAssertEqual(photos[1].transitionInFrames, 0, "previous one-frame photo leaves no overlap budget")
        XCTAssertEqual(project.shots[0].durationSeconds, 1.0 / 30.0, "normalization must not rewrite a v1 project")
    }

    func testTimelineRejectsIllegalLegacyDurationWithoutRewritingProject() throws {
        var project = renderProject(first: UUID(), second: UUID())
        project.shots[0].durationSeconds = -.infinity
        XCTAssertThrowsError(try TimeStoryTimeline.normalize(project: project))
        XCTAssertEqual(project.shots[0].durationSeconds, -.infinity)
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
            first: try edgeMarkedPNG(width: 1_200, height: 700),
            second: try edgeMarkedPNG(width: 700, height: 1_200),
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
        try await assertFourEdgesVisibleThroughoutPhotos(silent, project: project)

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

    func testStoryPackageExporterUsesCanonicalTimelineAndOnlyReferencedAssets() async throws {
        let root = try temporaryDirectory("story-package")
        let first = UUID()
        let second = UUID()
        let unused = candidate(UUID().uuidString, time: timestamp(2025, 1, 1))
        var project = renderProject(first: first, second: second)
        project.title = "用户修改的项目标题"
        project.chapters[0].title = "用户修改的章节标题"
        project.shots[0].caption = "用户修改的镜头字幕"
        project.candidateSnapshot = makeSnapshot(
            project.candidateSnapshot.candidates + [unused]
        )
        let loader = FixtureStoryMediaLoader(images: [
            first: try edgeMarkedPNG(width: 1_200, height: 700),
            second: try edgeMarkedPNG(width: 700, height: 1_200),
            unused.assetID: try pngData(color: .gray, portrait: false),
        ])
        let exporter = StoryRenderPackageExporter(media: loader, validator: PassingStoryValidator())
        let landscape = root.appendingPathComponent("landscape.storyrenderpackage")
        let portrait = root.appendingPathComponent("portrait.storyrenderpackage")
        let repeated = root.appendingPathComponent("repeated.storyrenderpackage")

        let landscapeResult = try await exporter.export(
            project: project,
            aspect: .landscape,
            destinationURL: landscape,
            onProgress: { _ in }
        )
        let portraitResult = try await exporter.export(
            project: project,
            aspect: .portrait,
            destinationURL: portrait,
            onProgress: { _ in }
        )
        let repeatedResult = try await exporter.export(
            project: project,
            aspect: .landscape,
            destinationURL: repeated,
            onProgress: { _ in }
        )
        let replacedInPlaceResult = try await exporter.export(
            project: project,
            aspect: .landscape,
            destinationURL: landscape,
            onProgress: { _ in }
        )
        let landscapeDocument = try packageDocument(at: landscape)
        var portraitDocument = try packageDocument(at: portrait)
        let repeatedDocument = try packageDocument(at: repeated)

        XCTAssertEqual(landscapeDocument.assets.count, 2, "unused candidate must not be exported")
        XCTAssertEqual(landscapeDocument.export.totalFrames, try TimeStoryTimeline.normalize(project: project).totalFrames)
        XCTAssertEqual(landscapeResult.totalFrames, project.timelineFrameCount)
        XCTAssertEqual(landscapeResult.projectRevision, repeatedResult.projectRevision)
        XCTAssertEqual(landscapeResult.projectRevision, replacedInPlaceResult.projectRevision)
        XCTAssertEqual(landscapeDocument, repeatedDocument)
        XCTAssertNotEqual(landscapeResult.projectRevision, portraitResult.projectRevision)
        XCTAssertEqual(landscapeDocument.export.width, 1_920)
        XCTAssertEqual(portraitDocument.export.width, 1_080)
        XCTAssertEqual(landscapeDocument.chapters.flatMap(\.shots).map(\.startFrame),
                       portraitDocument.chapters.flatMap(\.shots).map(\.startFrame))
        XCTAssertEqual(landscapeDocument.chapters.flatMap(\.shots).map(\.durationFrames),
                       portraitDocument.chapters.flatMap(\.shots).map(\.durationFrames))
        XCTAssertEqual(landscapeDocument.chapters.flatMap(\.shots).map(\.kind),
                       ["title", "chapter-title", "photo", "photo"])
        XCTAssertEqual(landscapeDocument.export.template.title, "用户修改的项目标题")
        XCTAssertEqual(landscapeDocument.chapters[0].title, "用户修改的章节标题")
        XCTAssertEqual(landscapeDocument.chapters[0].shots[2].caption?.body, "用户修改的镜头字幕")
        let json = try String(contentsOf: landscape.appendingPathComponent("story.json"), encoding: .utf8)
        XCTAssertFalse(json.contains(first.uuidString))
        XCTAssertFalse(json.contains(second.uuidString))
        XCTAssertFalse(json.contains(unused.assetID.uuidString))
        XCTAssertFalse(json.contains(project.subjectTagID.uuidString))

        portraitDocument.projectRevision = landscapeDocument.projectRevision
        portraitDocument.export.width = landscapeDocument.export.width
        portraitDocument.export.height = landscapeDocument.export.height
        XCTAssertEqual(portraitDocument, landscapeDocument, "orientation may only change canvas and content revision")
    }

    func testStoryPackageReplacementChangesOnlyRequestedAssetCaptionAndRevision() async throws {
        let root = try temporaryDirectory("story-package-modified")
        let first = UUID()
        let second = UUID()
        let replacement = UUID()
        let project = renderProject(first: first, second: second)
        var modified = project
        modified.shots[0].assetID = replacement
        modified.shots[0].contentRevision = 2
        modified.shots[0].caption = "只修改这一条字幕"
        modified.shots[0].isUserEdited = true
        let replacementCandidate = candidate(replacement.uuidString, time: timestamp(2020, 1, 1))
        modified.candidateSnapshot = makeSnapshot(
            project.candidateSnapshot.candidates + [replacementCandidate]
        )
        let loader = FixtureStoryMediaLoader(images: [
            first: try edgeMarkedPNG(width: 1_200, height: 700),
            second: try edgeMarkedPNG(width: 700, height: 1_200),
            replacement: try replacementPNG(width: 1_200, height: 700),
        ])
        let exporter = StoryRenderPackageExporter(media: loader, validator: PassingStoryValidator())
        let baselineURL = root.appendingPathComponent("baseline.storyrenderpackage")
        let modifiedURL = root.appendingPathComponent("modified.storyrenderpackage")
        _ = try await exporter.export(project: project, aspect: .landscape, destinationURL: baselineURL) { _ in }
        _ = try await exporter.export(project: modified, aspect: .landscape, destinationURL: modifiedURL) { _ in }
        let baseline = try packageDocument(at: baselineURL)
        let changed = try packageDocument(at: modifiedURL)

        XCTAssertNotEqual(baseline.projectRevision, changed.projectRevision)
        let baselineShots = baseline.chapters.flatMap(\.shots)
        let changedShots = changed.chapters.flatMap(\.shots)
        XCTAssertEqual(baselineShots.map(\.shotID), changedShots.map(\.shotID))
        XCTAssertEqual(baselineShots.map(\.startFrame), changedShots.map(\.startFrame))
        XCTAssertEqual(baselineShots.map(\.durationFrames), changedShots.map(\.durationFrames))
        XCTAssertEqual(baselineShots.map(\.transitionIn), changedShots.map(\.transitionIn))
        XCTAssertNotEqual(baselineShots[2].assetID, changedShots[2].assetID)
        XCTAssertNotEqual(baselineShots[2].caption, changedShots[2].caption)
        XCTAssertEqual(Array(baselineShots.dropFirst(3)), Array(changedShots.dropFirst(3)))
        XCTAssertEqual(baseline.assets[1], changed.assets[1], "unmodified second asset must stay byte-identical")
    }

    func testStoryPackageCancellationMissingMediaAndVersionChangeDoNotPublish() async throws {
        let root = try temporaryDirectory("story-package-failures")
        let first = UUID()
        let second = UUID()
        let project = renderProject(first: first, second: second)
        let existing = root.appendingPathComponent("existing.storyrenderpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel.txt")
        try Data("existing-good-package".utf8).write(to: sentinel)
        let slowExporter = StoryRenderPackageExporter(
            media: SlowStoryMediaLoader(data: try edgeMarkedPNG(width: 1_200, height: 700)),
            validator: PassingStoryValidator()
        )
        let task = Task {
            try await slowExporter.export(
                project: project,
                aspect: .landscape,
                destinationURL: existing,
                onProgress: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled package export unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "existing-good-package")

        let missingURL = root.appendingPathComponent("missing.storyrenderpackage")
        let missingExporter = StoryRenderPackageExporter(
            media: FixtureStoryMediaLoader(images: [
                first: try edgeMarkedPNG(width: 1_200, height: 700),
            ]),
            validator: PassingStoryValidator()
        )
        do {
            _ = try await missingExporter.export(
                project: project,
                aspect: .landscape,
                destinationURL: missingURL,
                onProgress: { _ in }
            )
            XCTFail("missing media export unexpectedly completed")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        }

        let changedURL = root.appendingPathComponent("changed.storyrenderpackage")
        let changingValidator = ChangingStoryValidator(assetID: first)
        let changingExporter = StoryRenderPackageExporter(
            media: FixtureStoryMediaLoader(images: [
                first: try edgeMarkedPNG(width: 1_200, height: 700),
                second: try edgeMarkedPNG(width: 700, height: 1_200),
            ]),
            validator: changingValidator
        )
        do {
            _ = try await changingExporter.export(
                project: project,
                aspect: .landscape,
                destinationURL: changedURL,
                onProgress: { _ in }
            )
            XCTFail("version-changing export unexpectedly completed")
        } catch let TimeStoryError.mediaValidationFailed(issues) {
            XCTAssertEqual(issues.map(\.kind), [.versionChanged])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: changedURL.path))
    }

    /// Opt-in delivery generator. It deliberately goes through the production
    /// package exporter and native renderer; no package JSON is post-processed.
    /// Set IMAGEALL_STORY_PHASE2_DELIVERY_ROOT to a new, non-existent directory.
    func testGeneratePhase2DeliverablesWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["IMAGEALL_STORY_PHASE2_DELIVERY_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("Set IMAGEALL_STORY_PHASE2_DELIVERY_ROOT to generate phase-2 delivery artifacts")
        }
        guard let schemaPath = environment["IMAGEALL_STORY_PHASE2_SCHEMA_PATH"], !schemaPath.isEmpty else {
            XCTFail("IMAGEALL_STORY_PHASE2_SCHEMA_PATH is required")
            return
        }
        let imageAllCommit = try XCTUnwrap(environment["IMAGEALL_STORY_PHASE2_IMAGEALL_COMMIT"])
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "delivery root must be new")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packages = root.appendingPathComponent("packages", isDirectory: true)
        let contract = root.appendingPathComponent("contract", isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: contract, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)

        let schemaSource = URL(fileURLWithPath: schemaPath)
        XCTAssertEqual(try fileSHA256(schemaSource), StoryRenderPackageExporter.schemaSHA256)
        let schemaCopy = contract.appendingPathComponent("story_render_package_v0_1.schema.json")
        try FileManager.default.copyItem(at: schemaSource, to: schemaCopy)

        let fixture = try phase2DeliveryFixture(in: evidence)
        let loader = FixtureStoryMediaLoader(images: fixture.images)
        let exporter = StoryRenderPackageExporter(media: loader, validator: PassingStoryValidator())
        let shortURL = packages.appendingPathComponent("01-short-landscape.storyrenderpackage", isDirectory: true)
        let fullLandscapeURL = packages.appendingPathComponent("02-full-60s-landscape.storyrenderpackage", isDirectory: true)
        let fullPortraitURL = packages.appendingPathComponent("03-full-60s-portrait.storyrenderpackage", isDirectory: true)
        let modifiedURL = packages.appendingPathComponent("04-full-60s-modified.storyrenderpackage", isDirectory: true)

        _ = try await exporter.export(project: fixture.short, aspect: .landscape, destinationURL: shortURL) { _ in }
        _ = try await exporter.export(project: fixture.full, aspect: .landscape, destinationURL: fullLandscapeURL) { _ in }
        _ = try await exporter.export(project: fixture.full, aspect: .portrait, destinationURL: fullPortraitURL) { _ in }
        _ = try await exporter.export(project: fixture.modified, aspect: .landscape, destinationURL: modifiedURL) { _ in }

        let shortDocument = try packageDocument(at: shortURL)
        let fullLandscape = try packageDocument(at: fullLandscapeURL)
        let fullPortrait = try packageDocument(at: fullPortraitURL)
        let modified = try packageDocument(at: modifiedURL)
        XCTAssertEqual(shortDocument.export.totalFrames, 198)
        XCTAssertEqual(fullLandscape.export.totalFrames, 1_800)
        XCTAssertEqual(fullPortrait.export.totalFrames, 1_800)
        XCTAssertEqual(modified.export.totalFrames, 1_800)
        XCTAssertEqual(fullLandscape.chapters.flatMap(\.shots).map(\.startFrame), fullPortrait.chapters.flatMap(\.shots).map(\.startFrame))
        XCTAssertEqual(fullLandscape.chapters.flatMap(\.shots).map(\.durationFrames), fullPortrait.chapters.flatMap(\.shots).map(\.durationFrames))

        let nativeVideo = evidence.appendingPathComponent("native-full-60s-landscape.mp4")
        let renderer = AVFoundationTimeStoryRenderer(
            media: loader,
            temporaryDirectory: evidence.appendingPathComponent("native-render-staging", isDirectory: true)
        )
        try await renderer.render(project: fixture.full, destinationURL: nativeVideo) { _ in }
        try await assertPlayableVideo(nativeVideo, expectsAudio: true, expectedDuration: 60)

        let packageRows = try [
            deliveryPackageRow(name: "short-landscape", url: shortURL, document: shortDocument),
            deliveryPackageRow(name: "full-60s-landscape", url: fullLandscapeURL, document: fullLandscape),
            deliveryPackageRow(name: "full-60s-portrait", url: fullPortraitURL, document: fullPortrait),
            deliveryPackageRow(name: "full-60s-modified", url: modifiedURL, document: modified),
        ]
        let handoffObject: [String: Any] = [
            "schemaVersion": StoryRenderPackageExporter.schemaVersion,
            "schemaCommit": StoryRenderPackageExporter.schemaCommit,
            "schemaSHA256": StoryRenderPackageExporter.schemaSHA256,
            "imageAllCommit": imageAllCommit,
            "generator": "TimeStoryFeatureTests/testGeneratePhase2DeliverablesWhenRequested",
            "packages": packageRows,
            "nativeVideo": [
                "relativePath": relativePath(nativeVideo, under: root),
                "sha256": try fileSHA256(nativeVideo),
                "fps": 30,
                "totalFrames": 1_800,
                "durationSeconds": 60,
            ],
            "scope": "synthetic fixtures only; generated by ImageAll exporter and native renderer",
        ]
        let handoffJSON = try JSONSerialization.data(withJSONObject: handoffObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try handoffJSON.write(to: root.appendingPathComponent("handoff.json"), options: .atomic)
        let handoffMarkdown = deliveryHandoffMarkdown(
            imageAllCommit: imageAllCommit,
            rows: packageRows,
            nativeVideo: nativeVideo,
            root: root
        )
        try Data(handoffMarkdown.utf8).write(to: root.appendingPathComponent("HANDOFF.md"), options: .atomic)

        let manifestLines = try regularFiles(under: root)
            .filter { $0.lastPathComponent != "FILE_HASHES.sha256" }
            .map { "\(try fileSHA256($0))  \(relativePath($0, under: root))" }
            .sorted()
        try Data((manifestLines.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("FILE_HASHES.sha256"), options: .atomic)
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

    private struct Phase2DeliveryFixture {
        let short: TimeStoryProject
        let full: TimeStoryProject
        let modified: TimeStoryProject
        let images: [UUID: Data]
    }

    private func phase2DeliveryFixture(in evidence: URL) throws -> Phase2DeliveryFixture {
        let assetIDs = (1 ... 6).map {
            UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", $0))!
        }
        let replacementID = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        let chapterIDs = (1 ... 3).map {
            UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", $0))!
        }
        let shotIDs = (1 ... 6).map {
            UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", $0))!
        }
        let sizes: [(CGFloat, CGFloat)] = [
            (1_200, 700), (700, 1_200), (900, 900), (1_600, 500), (640, 1_100), (1_300, 760),
        ]
        let candidates = zip(assetIDs, sizes).enumerated().map { index, pair in
            deliveryCandidate(
                assetID: pair.0,
                revision: 1,
                width: Int(pair.1.0),
                height: Int(pair.1.1),
                time: timestamp(2018 + index, 1, 1)
            )
        }
        let shots = candidates.enumerated().map { index, candidate in
            TimeStoryShot(
                id: shotIDs[index],
                assetID: candidate.assetID,
                contentRevision: 1,
                chapterID: chapterIDs[index / 2],
                caption: "合成字幕 \(index + 1)",
                durationSeconds: 9.2,
                presentationMode: .fullFrameWithBackground,
                reasons: ["第二阶段合成交付"],
                isLocked: true,
                isUserEdited: true
            )
        }
        let chapters = chapterIDs.enumerated().map { index, chapterID in
            TimeStoryChapter(
                id: chapterID,
                title: ["童年片段", "求学足迹", "近年时光"][index],
                shotIDs: Array(shots[(index * 2) ... (index * 2 + 1)].map(\.id)),
                isUserEdited: true
            )
        }
        let music = evidence.appendingPathComponent("synthetic-tone.wav")
        try writeSineWave(to: music, seconds: 2)
        let readiness = TimeStoryReadinessSummary(
            matchingCount: candidates.count,
            reliableTimeStartMs: candidates.first?.mediaCreatedAtMs,
            reliableTimeEndMs: candidates.last?.mediaCreatedAtMs,
            unknownTimeCount: 0,
            namedPlaceCount: 0,
            coordinateOnlyCount: 0,
            noLocationCount: 0,
            locationMetadataUnconfirmedCount: candidates.count,
            unavailableCount: 0,
            similarityFilteringState: .unavailable,
            selectionTradeoff: nil
        )
        let full = TimeStoryProject(
            schemaVersion: 1,
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            createdAtMs: 1,
            updatedAtMs: 1,
            subjectTagID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            subjectTagDisplayName: "合成测试人物",
            templateVersion: TimeStoryConstants.templateVersion,
            strategyVersion: TimeStoryConstants.strategyVersion,
            title: "合成测试人物 · 六年时光",
            candidateSnapshot: TimeStoryCandidateSnapshot(
                id: "phase2-delivery-fixture-v1",
                createdAtMs: 1,
                tagID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                tagDisplayName: "合成测试人物",
                candidates: candidates
            ),
            readiness: readiness,
            chapters: chapters,
            shots: shots,
            excludedAssetIDs: [],
            music: TimeStoryMusicSelection(displayName: music.lastPathComponent, filePath: music.path, securityScopedBookmark: nil)
        )
        var modified = full
        let replacement = deliveryCandidate(
            assetID: replacementID,
            revision: 2,
            width: 1_200,
            height: 700,
            time: timestamp(2018, 1, 1)
        )
        modified.shots[0].assetID = replacementID
        modified.shots[0].contentRevision = 2
        modified.shots[0].caption = "仅这一条字幕已修改"
        modified.candidateSnapshot = TimeStoryCandidateSnapshot(
            id: "phase2-delivery-fixture-v2-one-replacement",
            createdAtMs: 2,
            tagID: full.candidateSnapshot.tagID,
            tagDisplayName: full.candidateSnapshot.tagDisplayName,
            candidates: [replacement] + Array(candidates.dropFirst())
        )
        var short = full
        short = TimeStoryProject(
            schemaVersion: short.schemaVersion,
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            createdAtMs: 1,
            updatedAtMs: 1,
            subjectTagID: short.subjectTagID,
            subjectTagDisplayName: short.subjectTagDisplayName,
            templateVersion: short.templateVersion,
            strategyVersion: short.strategyVersion,
            title: "合成短故事",
            candidateSnapshot: TimeStoryCandidateSnapshot(
                id: "phase2-short-fixture-v1",
                createdAtMs: 1,
                tagID: short.subjectTagID,
                tagDisplayName: short.subjectTagDisplayName,
                candidates: Array(candidates.prefix(2))
            ),
            readiness: readiness,
            chapters: [TimeStoryChapter(
                id: chapterIDs[0],
                title: "短故事章节",
                shotIDs: Array(shotIDs.prefix(2)),
                isUserEdited: true
            )],
            shots: Array(shots.prefix(2)).map { shot in
                var adjusted = shot
                adjusted.durationSeconds = 1.5
                adjusted.chapterID = chapterIDs[0]
                return adjusted
            },
            excludedAssetIDs: [],
            music: nil
        )
        var images: [UUID: Data] = [:]
        for (index, assetID) in assetIDs.enumerated() {
            images[assetID] = try edgeMarkedPNG(width: sizes[index].0, height: sizes[index].1)
        }
        images[replacementID] = try replacementPNG(width: 1_200, height: 700)
        return Phase2DeliveryFixture(short: short, full: full, modified: modified, images: images)
    }

    private func deliveryCandidate(
        assetID: UUID,
        revision: Int,
        width: Int,
        height: Int,
        time: Int64
    ) -> TimeStoryCandidate {
        TimeStoryCandidate(
            assetID: assetID,
            contentRevision: revision,
            sourceID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            fileName: nil,
            mediaCreatedAtMs: time,
            width: width,
            height: height,
            availability: .available,
            isFavorite: false,
            locationState: .unconfirmed,
            placeName: nil,
            locationSource: nil,
            similarityClusterID: nil,
            similarityState: .unavailable
        )
    }

    private func deliveryPackageRow(
        name: String,
        url: URL,
        document: StoryRenderPackageDocument
    ) throws -> [String: Any] {
        [
            "name": name,
            "relativePath": url.lastPathComponent,
            "storyJSONSHA256": try fileSHA256(url.appendingPathComponent("story.json")),
            "projectRevision": document.projectRevision,
            "canvas": "\(document.export.width)x\(document.export.height)",
            "fps": document.export.fps,
            "totalFrames": document.export.totalFrames,
            "chapterCount": document.chapters.count,
            "renderSegmentCount": document.chapters.flatMap(\.shots).count,
            "photoShotCount": document.chapters.flatMap(\.shots).filter { $0.kind == "photo" }.count,
            "assetCount": document.assets.count,
        ]
    }

    private func deliveryHandoffMarkdown(
        imageAllCommit: String,
        rows: [[String: Any]],
        nativeVideo: URL,
        root: URL
    ) -> String {
        let tableRows = rows.map { row in
            "| \(row["name"]!) | `packages/\(row["relativePath"]!)` | \(row["canvas"]!) | \(row["chapterCount"]!)/\(row["photoShotCount"]!)/\(row["renderSegmentCount"]!)/\(row["totalFrames"]!) | `\(row["storyJSONSHA256"]!)` |"
        }.joined(separator: "\n")
        return """
        # ImageAll StoryRenderPackage phase 2 handoff

        - Schema: StoryRenderPackage v\(StoryRenderPackageExporter.schemaVersion)
        - Schema commit: `\(StoryRenderPackageExporter.schemaCommit)`
        - Schema SHA-256: `\(StoryRenderPackageExporter.schemaSHA256)`
        - ImageAll commit: `\(imageAllCommit)`
        - Generator: `TimeStoryFeatureTests/testGeneratePhase2DeliverablesWhenRequested`
        - Data boundary: synthetic fixtures only

        | Package | Relative path | Canvas | Chapters/photos/segments/frames | story.json SHA-256 |
        | --- | --- | --- | --- | --- |
        \(tableRows)

        Native 60-second evidence: `\(relativePath(nativeVideo, under: root))` (`\((try? fileSHA256(nativeVideo)) ?? "hash-error")`).

        `FILE_HASHES.sha256` records every delivered file. Package JSON and normalized media were emitted by the actual ImageAll exporter and were not edited after export.
        """
    }

    private func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func regularFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { return nil }
            return url
        }
    }

    private func relativePath(_ url: URL, under root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
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

    private func edgeMarkedPNG(width: CGFloat, height: CGFloat) throws -> Data {
        try markedPNG(width: width, height: height, replacement: false)
    }

    private func replacementPNG(width: CGFloat, height: CGFloat) throws -> Data {
        try markedPNG(width: width, height: height, replacement: true)
    }

    private func markedPNG(width: CGFloat, height: CGFloat, replacement: Bool) throws -> Data {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        (replacement ? NSColor.systemPink : NSColor.white).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let border = max(18, min(width, height) * 0.06)
        NSColor.systemRed.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: height - border, width: width, height: border)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: border)).fill()
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: border, height: height)).fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(rect: NSRect(x: width - border, y: 0, width: border, height: height)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("Unable to create edge-marked PNG") }
        return data
    }

    private func packageDocument(at root: URL) throws -> StoryRenderPackageDocument {
        try JSONDecoder().decode(
            StoryRenderPackageDocument.self,
            from: Data(contentsOf: root.appendingPathComponent("story.json"))
        )
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

    private func assertFourEdgesVisibleThroughoutPhotos(
        _ videoURL: URL,
        project: TimeStoryProject
    ) async throws {
        let timeline = try TimeStoryTimeline.normalize(project: project)
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, segment) in timeline.segments.enumerated() where segment.kind == .photo {
            let previousEnd = index > 0 ? timeline.segments[index - 1].endFrame : segment.startFrame
            let nextStart = index + 1 < timeline.segments.count
                ? timeline.segments[index + 1].startFrame
                : segment.endFrame
            let visibleStart = max(segment.startFrame, previousEnd)
            let visibleEnd = min(segment.endFrame, nextStart)
            XCTAssertGreaterThan(visibleEnd - visibleStart, 4)
            for frame in [visibleStart + 1, (visibleStart + visibleEnd) / 2, visibleEnd - 2] {
                let time = CMTime(value: CMTimeValue(frame * 1_000 + 500), timescale: 30_000)
                let image = try await generator.image(at: time).image
                let counts = edgeMarkerCounts(image)
                XCTAssertGreaterThan(counts.red, 50, "top/red edge missing at frame \(frame)")
                XCTAssertGreaterThan(counts.green, 50, "left/green edge missing at frame \(frame)")
                XCTAssertGreaterThan(counts.blue, 50, "bottom/blue edge missing at frame \(frame)")
                XCTAssertGreaterThan(counts.yellow, 50, "right/yellow edge missing at frame \(frame)")
            }
        }
    }

    private func edgeMarkerCounts(_ image: CGImage) -> (red: Int, green: Int, blue: Int, yellow: Int) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return (0, 0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts = (red: 0, green: 0, blue: 0, yellow: 0)
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                if red > 140, green < 135, blue < 135 { counts.red += 1 }
                if green > 110, red < 135, blue < 145 { counts.green += 1 }
                if blue > 140, red < 135, green < 170 { counts.blue += 1 }
                if red > 140, green > 140, blue < 135 { counts.yellow += 1 }
            }
        }
        return counts
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

private struct PassingStoryValidator: TimeStoryMediaValidating {
    func validate(_ project: TimeStoryProject) throws -> [TimeStoryMediaValidationIssue] { [] }
}

private struct SlowStoryMediaLoader: TimeStoryMediaLoading {
    let data: Data

    func loadStoryImage(assetID: UUID) async throws -> Data {
        try await Task.sleep(for: .seconds(5))
        return data
    }
}

private final class ChangingStoryValidator: TimeStoryMediaValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let assetID: UUID

    init(assetID: UUID) { self.assetID = assetID }

    func validate(_ project: TimeStoryProject) throws -> [TimeStoryMediaValidationIssue] {
        let call = lock.withLock {
            callCount += 1
            return callCount
        }
        guard call > 1 else { return [] }
        return [TimeStoryMediaValidationIssue(
            shotIndex: 1,
            assetID: assetID,
            kind: .versionChanged,
            expectedRevision: 1,
            actualRevision: 2
        )]
    }
}
