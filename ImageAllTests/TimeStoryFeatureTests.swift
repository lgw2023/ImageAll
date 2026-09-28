import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import CryptoKit
import GRDB
@testable import ImageAll
import XCTest

final class TimeStoryFeatureTests: XCTestCase {
    func testOpenMontageConfigurationAndDetachGate() throws {
        let suite = "OpenMontageConfig-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var connection = OpenMontageConfiguration.ModelConnection()
        connection.baseURL = "https://example.com/compatible-mode/v1"
        connection.model = "user-selected-model"
        XCTAssertEqual(connection.completionURL, "https://example.com/compatible-mode/v1/chat/completions")
        connection.baseURL = connection.completionURL
        try connection.validate()
        XCTAssertFalse(connection.completionURL.contains("chat/completions/chat/completions"))
        connection.extraBody = "{\"model\":\"override\"}"
        XCTAssertThrowsError(try connection.validate())
        connection.extraBody = "{\"enable_thinking\":false}"
        try connection.validate()
        var value = OpenMontageConfiguration()
        XCTAssertNil(try JSONDecoder().decode(OpenMontageConfiguration.self, from: JSONEncoder().encode(value)).connection)
        value.connection = connection
        value.llm.model = "test-model"
        try value.validate()
        defaults.set(try JSONEncoder().encode(value), forKey: OpenMontageConfiguration.configurationKey)
        XCTAssertEqual(try OpenMontageConfiguration.load(defaults), value)
        value.paths.output_dir = "../escape"
        XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try OpenMontageServiceField.validate(["PATH": "/tmp"]))
        XCTAssertThrowsError(try OpenMontageServiceField.validate(["OPENAI_BASE_URL": "http://remote.example/v1"]))
        XCTAssertNoThrow(try OpenMontageServiceField.validate(["OPENAI_BASE_URL": "http://localhost:11434/v1", "OPENAI_API_KEY": "synthetic-only"]))
        defaults.set(false, forKey: OpenMontageConfiguration.enabledKey)
        let root = try temporaryDirectory("detached-engine").appendingPathComponent("tasks")
        let store = UserDefaultsOpenMontageTaskRootStore(defaults: defaults, managedRoot: root)
        XCTAssertThrowsError(try store.resolveTaskRoot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testManagedOpenMontageDirectoryAndInvalidExistingAuthorization() throws {
        let suite = "OpenMontageTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory("managed-engine").appendingPathComponent("tasks")
        let store = UserDefaultsOpenMontageTaskRootStore(defaults: defaults, managedRoot: root)
        XCTAssertEqual(try store.resolveTaskRoot(), root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(store.startAccessing(root))
        store.stopAccessing(root)
        defaults.set(Data("invalid bookmark".utf8), forKey: UserDefaultsOpenMontageTaskRootStore.bookmarkKey)
        XCTAssertThrowsError(try store.resolveTaskRoot()) // Never silently switch away from an authorized queue.
    }

    func testTaskRootRenewalAndRejectedReplacementPreserveQueue() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TaskRoot-" + UUID().uuidString))
        let root = try temporaryDirectory("task-root-grant")
        let port = StoryTaskRootBookmarkFixture(url: root)
        let store = UserDefaultsOpenMontageTaskRootStore(defaults: defaults, bookmarks: port)
        defaults.set(Data("old".utf8), forKey: UserDefaultsOpenMontageTaskRootStore.bookmarkKey)
        XCTAssertEqual(try store.resolveTaskRoot(), root)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsOpenMontageTaskRootStore.bookmarkKey), Data("fresh".utf8))
        XCTAssertEqual(port.active, 0)
        port.reject = true
        XCTAssertThrowsError(try store.saveTaskRoot(root))
        XCTAssertEqual(defaults.data(forKey: UserDefaultsOpenMontageTaskRootStore.bookmarkKey), Data("fresh".utf8))
        XCTAssertEqual(port.active, 0)
        port.reject = false
        try store.saveTaskRoot(root)
        XCTAssertEqual(try store.resolveTaskRoot(), root)
        XCTAssertEqual(port.active, 0)
    }

    func testFramingGeometryPersistenceAndDerivedExport() throws {
        let image = CGSize(width: 600, height: 1200), canvas = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(TimeStoryPresentationMode.aspectFill.imageRect(image: image, canvas: canvas),
                       CGRect(x: 0, y: -1380, width: 1920, height: 3840))
        XCTAssertEqual(TimeStoryPresentationMode.aspectFitBlack.imageRect(image: image, canvas: canvas),
                       CGRect(x: 690, y: 0, width: 540, height: 1080))
        var project = renderProject(first: UUID(), second: UUID())
        for mode in TimeStoryPresentationMode.allCases {
            project.shots[0].presentationMode = mode
            let decoded = try JSONDecoder().decode(TimeStoryProject.self, from: JSONEncoder().encode(project))
            XCTAssertEqual(decoded.shots[0].presentationMode, mode)
            XCTAssertEqual(try TimeStoryTimeline.normalize(project: decoded).segments.first(where: { $0.kind == .photo })?.presentationMode, mode)
        }
        let root = try temporaryDirectory("framing")
        for aspect in TimeStoryPackageAspect.allCases {
            for mode in [TimeStoryPresentationMode.aspectFill, .aspectFitBlack] {
                let url = root.appendingPathComponent("\(aspect.rawValue)-\(mode.rawValue).jpg")
                try StoryRenderPackageExporter.writeNormalizedJPEG(try pngData(color: .red, portrait: false),
                    to: url, mode: mode, aspect: aspect)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(output.width, aspect.width)
                XCTAssertEqual(output.height, aspect.height)
                let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: output).colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
                if mode == .aspectFill { XCTAssertGreaterThan(pixel.redComponent, 0.8) }
                else { XCTAssertLessThan(pixel.redComponent, 0.1) }
            }
        }
    }

    func testStyleTemplatePersistenceVariantAndRequestBinding() async throws {
        let root = try temporaryDirectory("style-template")
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        project.shots[0].durationSeconds = 2
        project.shots[0].isLocked = true
        let shots = project.shots
        project.styleTemplate = .init(template: StoryStyleTemplate.builtins[1], lines: ["风从草地经过", "把蓝色留在眼里"])
        let store = TimeStoryProjectStore(applicationSupportDirectory: root)
        try store.save(project)
        XCTAssertEqual(try store.load(project.id).styleTemplate, project.styleTemplate)
        XCTAssertEqual(try store.load(project.id).shots, shots)
        let catalog = StoryStyleCatalog(directory: root.appendingPathComponent("templates-library"))
        let variant = try catalog.saveVariant(project.styleTemplate!.template, name: "个人样式")
        XCTAssertNotEqual(variant.id, project.styleTemplate!.template.id)
        XCTAssertEqual(try catalog.load().count, 3)
        let stored = try String(contentsOf: catalog.directory.appendingPathComponent(variant.id + ".json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("风从草地经过"))
        XCTAssertFalse(stored.contains(first.uuidString))
        let capability = StoryStyleExchange.Capability(protocolVersion: "1.0", implementations: [variant.implementation: String(repeating: "a", count: 64)], ready: true, detail: "", updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try StoryCreativePlugin.encode(capability).write(to: root.appendingPathComponent("templates/capabilities.json"))
        let exchange = StoryStyleExchange(rootProvider: FixtureOpenMontageRootProvider(root: root), exporter: StoryRenderPackageExporter(media: FixtureStoryMediaLoader(images: [first: try pngData(color: .red, portrait: true), second: try pngData(color: .blue, portrait: false)]), validator: PassingStoryValidator()))
        let receipt = try await exchange.publish(project)
        let requestURL = root.appendingPathComponent("templates/requests/\(receipt.requestID)/request.json")
        let data = try Data(contentsOf: requestURL)
        XCTAssertEqual(StoryCreativePlugin.hash(data), receipt.requestSHA256)
        let request = try JSONDecoder().decode(StoryStyleExchange.Request.self, from: data)
        XCTAssertEqual(request.photoFrames, shots.map { Int(($0.durationSeconds * 30).rounded()) })
        XCTAssertEqual(request.photoIDs, shots.map { StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: $0.assetID) })
        XCTAssertEqual(request.style, project.styleTemplate)
        var invalid = variant; invalid.fontSize = 300
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testAtelierSyntheticCatalogHasOnlyBoundedReliableCandidates() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        _ = try TimeStoryVerificationContainer.seedSyntheticCatalog(database, atelierMode: true)
        let snapshot = try TimeStoryCandidateProvider(
            database: database, query: GRDBAssetCatalogQueryRepository(database: database)
        ).snapshot(tag: TimeStoryVerificationContainer.subject, nowMs: 1)
        XCTAssertEqual(snapshot.candidates.count, 22)
        XCTAssertEqual(snapshot.candidates.filter { $0.availability == .available }.count, 21)
        XCTAssertTrue(snapshot.candidates.filter { $0.availability == .available }
            .allSatisfy { $0.mediaCreatedAtMs != nil })
    }

    @MainActor
    func testWorkspaceVideoClipRequestApplyAndPhotoDurationProtection() async throws {
        let root = try temporaryDirectory("story-clip-ui")
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        video.mediaKind = .video; video.durationMs = 1000
        let project = TimeStoryPlanner().makeFreeformProject(snapshot: makeSnapshot([video]), nowMs: 1)
        let source = root.appendingPathComponent("moving.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: source)
        let media = FixtureMixedStoryMedia(images: [:], video: source)
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let roots = FixtureOpenMontageRootProvider(root: root)
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(database: database, query: GRDBAssetCatalogQueryRepository(database: database)),
            planner: TimeStoryPlanner(), store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: PassingStoryValidator(), renderer: AVFoundationTimeStoryRenderer(media: media, temporaryDirectory: root),
            packageExporter: exporter, openMontageTasks: FileOpenMontageStoryTaskClient(rootProvider: roots, packageExporter: exporter, installationID: "fixture"),
            creativeRootProvider: roots, media: media, clock: SystemJobClock())
        let model = TimeStoryWorkspaceModel(verificationRuntime: runtime,
            tag: TagListItem(id: project.subjectTagID, displayName: "Synthetic", state: .active), project: project, thumbnails: [:])
        await model.addCandidate(video)
        XCTAssertTrue(model.project?.shots.isEmpty == true)
        let request = try XCTUnwrap(model.videoClipRequest)
        let resource = try await model.prepareClipPreview(request, destination: root.appendingPathComponent("preview.mov"))
        XCTAssertEqual(resource.contentRevision, video.contentRevision)
        var loaded = false
        let host = NSHostingView(rootView: StoryVideoClipEditor(request: request,
            load: { destination in
                let value = try await model.prepareClipPreview(request, destination: destination)
                loaded = true
                return value
            }, save: { model.applyVideoClip(request, clip: $0) }, cancel: { model.videoClipRequest = nil })
            .frame(width: 660, height: 560).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<30 where !loaded { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(loaded)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000)
        if let directory = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let target = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try png.write(to: target.appendingPathComponent("story-video-clip-editor.png"))
        }
        let clip = TimeStoryVideoClip(inPointMs: 200, outPointMs: 800, sourceDurationMs: 1000, originalAudioGain: 0.25)
        model.applyVideoClip(request, clip: clip)
        let shot = try XCTUnwrap(model.project?.shots.first)
        XCTAssertEqual(shot.videoClip, clip)
        XCTAssertEqual(shot.durationSeconds, 0.6, accuracy: 0.0001)
        XCTAssertGreaterThan(model.project?.timelineDurationSeconds ?? 0, 0)
        XCTAssertNil(model.videoClipRequest)
        model.setDuration(shot.id, seconds: 10)
        model.editShots([shot.id], duration: 10)
        XCTAssertEqual(model.project?.shots.first?.durationSeconds, 0.6)
        model.editVideoClip(shot.id)
        XCTAssertEqual(model.videoClipRequest?.initial, clip)
        model.setMusic(url: root.appendingPathComponent("tone.wav"))
        model.setMusicVolume(0.5)
        XCTAssertEqual(model.project?.music?.volume, 0.5)
        model.setMusicVolume(2)
        XCTAssertEqual(model.project?.music?.volume, 0.5)
    }

    func testManualVideoCandidatesRequireExplicitClipsAndAllowDistinctSegments() throws {
        let photo = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 2))
        video.mediaKind = .video
        video.durationMs = 4000
        let planner = TimeStoryPlanner()
        let snapshot = makeSnapshot([photo, video])
        let automatic = try planner.makeProject(snapshot: snapshot, nowMs: 1)
        XCTAssertEqual(automatic.shots.map(\.assetID), [photo.assetID])
        var manual = planner.makeFreeformProject(snapshot: snapshot, nowMs: 1)
        XCTAssertThrowsError(try planner.manuallyInserting(video, in: manual, nowMs: 2))
        let first = TimeStoryVideoClip(inPointMs: 0, outPointMs: 1000, sourceDurationMs: 4000)
        manual = try planner.manuallyInserting(video, in: manual, nowMs: 2, videoClip: first)
        let second = TimeStoryVideoClip(inPointMs: 2000, outPointMs: 3500, sourceDurationMs: 4000, originalAudioGain: 0)
        manual = try planner.manuallyInserting(video, in: manual, nowMs: 3, videoClip: second)
        XCTAssertEqual(manual.shots.map(\.videoClip), [first, second])
        XCTAssertEqual(manual.shots.map(\.durationSeconds), [1, 1.5])
        XCTAssertEqual(Set(manual.shots.map(\.id)).count, 2)
        XCTAssertFalse(planner.manuallyEditableCandidates(in: manual, replacing: manual.shots[0].id).contains(video))
        XCTAssertThrowsError(try planner.manuallyInserting(photo, in: manual, nowMs: 4, videoClip: first))
        let restored = try JSONDecoder().decode(TimeStoryProject.self, from: JSONEncoder().encode(manual))
        XCTAssertEqual(restored.shots, manual.shots)
        XCTAssertThrowsError(try TimeStoryTimeline.normalize(project: restored), "Unimplemented render path must reject clips")
    }

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
        try database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET media_kind = 'video', duration_ms = 4000 WHERE id = ?",
                arguments: [secondID.uuidString.lowercased()])
        }
        let first = projection(firstID, sourceID: firstSource, time: timestamp(2019, 1, 1))
        let second = projection(secondID, sourceID: secondSource, time: timestamp(2025, 1, 1))
        let query = PagingStoryQuery(first: first, second: second)
        let tag = TagListItem(id: UUID(), displayName: "任意主体", state: .active)

        let snapshot = try TimeStoryCandidateProvider(database: database, query: query)
            .snapshot(tag: tag, nowMs: 123)

        XCTAssertEqual(query.requests.count, 2)
        XCTAssertTrue(query.requests.allSatisfy { $0.limit == 200 && $0.sort == .embeddedTimeOldest })
        XCTAssertEqual(query.requests.first?.filter.tagDecisionFilters, [
            TagDecisionFilter(tagID: tag.id, decision: .accepted),
        ])
        XCTAssertEqual(query.requests.first?.filter.availabilities, [.available, .missing, .unreadable, .unsupported])
        XCTAssertEqual(snapshot.candidates.map(\.assetID), [firstID, secondID])
        XCTAssertEqual(query.requests.first?.filter.mediaKinds, [.image, .video])
        XCTAssertEqual(snapshot.candidates.map(\.effectiveMediaKind), [.image, .video])
        XCTAssertEqual(snapshot.candidates.last?.durationMs, 4000)
        XCTAssertEqual(snapshot.candidates.map(\.locationState), [.unconfirmed, .unconfirmed])
        XCTAssertTrue(snapshot.id.hasPrefix("sha256:"))
    }

    @MainActor
    func testPhase4CatalogReadinessEditsAndLegacyProject() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        _ = try TimeStoryVerificationContainer.seedSyntheticCatalog(database)
        let provider = TimeStoryCandidateProvider(
            database: database, query: GRDBAssetCatalogQueryRepository(database: database)
        )
        let tag = TimeStoryVerificationContainer.subject
        let snapshot = try provider.snapshot(tag: tag, nowMs: 1)
        let details = TimeStoryReadinessDetails(candidates: snapshot.candidates)
        let planner = TimeStoryPlanner()
        let readiness = planner.readiness(for: snapshot)
        XCTAssertEqual(snapshot.candidates.count, 511, "必须跨越实际 200 条查询边界")
        XCTAssertEqual(snapshot.pendingReviewCount, 1)
        XCTAssertEqual(details.available, 510)
        XCTAssertEqual(readiness.unavailableCount, 1)
        XCTAssertEqual(readiness.unknownTimeCount, 1)
        XCTAssertEqual(readiness.namedPlaceCount, 2)
        XCTAssertEqual(details.namedAssets, 508)
        XCTAssertEqual(readiness.coordinateOnlyCount, 1)
        XCTAssertEqual(readiness.noLocationCount, 1)
        XCTAssertEqual(readiness.locationMetadataUnconfirmedCount, 1)
        XCTAssertEqual(details.analyzedAssets, 505)
        XCTAssertEqual(details.duplicateGroups, 252)
        XCTAssertEqual(details.assetsInDuplicateGroups, 504)
        for excludedNumber in [11, 12, 13] {
            let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", excludedNumber))!
            XCTAssertFalse(snapshot.candidates.contains { $0.assetID == id })
        }
        var project = try planner.makeProject(snapshot: snapshot, nowMs: 2)
        let ids = Set(project.shots.map(\.assetID))
        func asset(_ number: Int) -> UUID {
            UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!
        }
        XCTAssertTrue(ids.contains(asset(1)))
        XCTAssertTrue(ids.contains(asset(4)))
        XCTAssertTrue(ids.contains(asset(6)))
        XCTAssertFalse(ids.contains(asset(3)), "同事件相似照片不重复入选")
        XCTAssertFalse(ids.contains(asset(8)), "未知时间不伪造顺序")
        XCTAssertFalse(ids.contains(asset(9)), "不可用照片不入选")
        XCTAssertEqual(project.chapters.map(\.title).filter { ["A 城", "B 城"].contains($0) },
                       ["A 城", "B 城", "A 城"])
        let repeated = try planner.makeProject(snapshot: snapshot, nowMs: 2)
        XCTAssertEqual(project.shots.map(\.assetID), repeated.shots.map(\.assetID))
        XCTAssertEqual(project.shots.map(\.reasons), repeated.shots.map(\.reasons))
        let first = try XCTUnwrap(project.shots.first(where: { $0.assetID == asset(1) }))
        let replacementTarget = try XCTUnwrap(project.shots.first(where: { $0.assetID == asset(2) }))
        XCTAssertEqual(planner.replacementCandidates(for: replacementTarget.id, in: project).map(\.assetID),
                       [asset(3)])
        let replacementIndex = try XCTUnwrap(project.shots.firstIndex(where: { $0.id == replacementTarget.id }))
        project.shots[replacementIndex].assetID = asset(3)
        project.shots[replacementIndex].contentRevision = 1
        project.shots[replacementIndex].caption = "手动字幕"
        project.shots[replacementIndex].isLocked = true
        project.shots[replacementIndex].isUserEdited = true
        project.excludedAssetIDs.insert(asset(2))
        project.excludedAssetIDs.insert(asset(4))
        let middleChapter = try XCTUnwrap(project.chapters.first(where: { $0.title == "B 城" }))
        project.chapterTitleOverrides = [middleChapter.id: "B 城 · 中期"]
        project.shots.removeAll { $0.assetID == asset(4) }
        project.chapters.removeAll { $0.id == middleChapter.id }
        let lockedIndex = try XCTUnwrap(project.shots.firstIndex(where: { $0.id == first.id }))
        project.shots[lockedIndex].isLocked = true
        project.shots[lockedIndex].durationSeconds = 7
        project.shots[lockedIndex].isUserEdited = true
        let regenerated = try planner.makeProject(snapshot: snapshot, nowMs: 3, existing: project)
        XCTAssertTrue(regenerated.shots.contains { $0.assetID == asset(3) && $0.caption == "手动字幕" && $0.isLocked })
        XCTAssertFalse(regenerated.shots.contains { [asset(2), asset(4)].contains($0.assetID) })
        XCTAssertEqual(regenerated.chapters.first(where: { $0.shotIDs.contains(where: { shotID in
            regenerated.shots.contains(where: { $0.id == shotID && $0.assetID == asset(5) })
        }) })?.title, "B 城 · 中期")
        XCTAssertEqual(regenerated.shots.first(where: { $0.id == first.id })?.durationSeconds, 7)
        var crowded = regenerated
        for candidate in snapshot.candidates where crowded.shots.count < 19 && candidate.availability == .available {
            guard !crowded.shots.contains(where: { $0.assetID == candidate.assetID }),
                  !crowded.excludedAssetIDs.contains(candidate.assetID),
                  candidate.mediaCreatedAtMs != nil
            else { continue }
            crowded.shots.append(TimeStoryShot(
                id: UUID(), assetID: candidate.assetID, contentRevision: candidate.contentRevision,
                chapterID: crowded.shots[0].chapterID, caption: "锁定", durationSeconds: 3,
                presentationMode: .fullFrameWithBackground, reasons: ["用户锁定"],
                isLocked: true, isUserEdited: false
            ))
        }
        for index in crowded.shots.indices { crowded.shots[index].isLocked = true }
        XCTAssertEqual(crowded.shots.count, 19)
        XCTAssertThrowsError(try planner.makeProject(snapshot: snapshot, nowMs: 4, existing: crowded)) { error in
            guard case TimeStoryError.capacityConflict(19) = error else {
                return XCTFail("19 个锁定镜头必须报告具体容量冲突：\(error)")
            }
        }
        let store = TimeStoryProjectStore(applicationSupportDirectory: try temporaryDirectory("phase4-store"))
        try store.save(regenerated)
        XCTAssertEqual(try store.load(regenerated.id), regenerated)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(regenerated)) as? [String: Any])
        legacyJSON.removeValue(forKey: "chapterTitleOverrides")
        var legacySnapshot = try XCTUnwrap(legacyJSON["candidateSnapshot"] as? [String: Any])
        legacySnapshot.removeValue(forKey: "pendingReviewCount")
        legacySnapshot["candidates"] = try XCTUnwrap(legacySnapshot["candidates"] as? [[String: Any]]).map { row in
            var old = row
            old.removeValue(forKey: "captureTimeSource")
            return old
        }
        legacyJSON["candidateSnapshot"] = legacySnapshot
        let old = try JSONDecoder().decode(TimeStoryProject.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(old.candidateSnapshot.pendingReviewCount)
        XCTAssertNil(old.chapterTitleOverrides)
        XCTAssertTrue(old.candidateSnapshot.candidates.allSatisfy { $0.captureTimeSource == nil })
        try database.pool.write { db in
            try db.execute(sql: "UPDATE asset SET content_revision = 2 WHERE id = ?", arguments: [asset(1).uuidString.lowercased()])
        }
        let changed = try provider.snapshot(tag: tag, nowMs: 4)
        XCTAssertNotEqual(changed.id, snapshot.id)
        XCTAssertThrowsError(try planner.makeProject(snapshot: changed, nowMs: 5, existing: regenerated)) { error in
            guard case TimeStoryError.preservedMediaChanged = error else {
                return XCTFail("锁定素材版本变化必须明确报错：\(error)")
            }
        }
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

    func testPlannerKeepsGrowthCoverageWhenFavoritesClusterWithinOneDay() throws {
        func make(_ number: Int, time: Int64, favorite: Bool = false) -> TimeStoryCandidate {
            candidate(
                String(format: "00000000-0000-0000-0000-%012d", number),
                time: time,
                favorite: favorite
            )
        }
        let early = (1 ... 4).map { make($0, time: timestamp(2018, $0 * 2, 1)) }
        let middle = (5 ... 8).map { make($0, time: timestamp(2022, ($0 - 4) * 2, 1)) }
        let burstStart = timestamp(2026, 1, 1)
        let burst = (9 ... 38).map {
            make($0, time: burstStart + Int64($0 - 9) * 60_000, favorite: true)
        }
        let later = (39 ... 65).map {
            make($0, time: timestamp(2026, 1, 2) + Int64($0 - 39) * 86_400_000)
        }
        let snapshot = makeSnapshot(early + middle + burst + later)

        let project = try TimeStoryPlanner().makeProject(snapshot: snapshot, nowMs: 10)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.candidates.map { ($0.assetID, $0) })
        let selectedTimes = project.shots.compactMap { byID[$0.assetID]?.mediaCreatedAtMs }

        XCTAssertEqual(project.shots.count, TimeStoryConstants.maximumShots)
        XCTAssertGreaterThanOrEqual(selectedTimes.filter { $0 < timestamp(2020, 1, 1) }.count, 3)
        XCTAssertGreaterThanOrEqual(selectedTimes.filter { $0 >= timestamp(2022, 1, 1) && $0 < timestamp(2023, 1, 1) }.count, 3)
        XCTAssertLessThanOrEqual(selectedTimes.filter { abs($0 - burstStart) < 86_400_000 }.count, 2)
    }

    func testPlannerSpreadsRemainingSeatsAcrossCapturePeriods() throws {
        func make(_ number: Int, year: Int, month: Int, favorite: Bool) -> TimeStoryCandidate {
            candidate(
                String(format: "00000000-0000-0000-0000-%012d", number),
                time: timestamp(year, month, 1),
                favorite: favorite
            )
        }
        let olderFavorites = (1 ... 12).map { make($0, year: 2024, month: $0, favorite: true) }
        let middle = (1 ... 12).map { make(100 + $0, year: 2025, month: $0, favorite: false) }
        let recent = (1 ... 12).map { make(200 + $0, year: 2026, month: $0, favorite: false) }
        let snapshot = makeSnapshot(olderFavorites + middle + recent)

        let project = try TimeStoryPlanner().makeProject(snapshot: snapshot, nowMs: 10)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.candidates.map { ($0.assetID, $0) })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let years = project.shots.compactMap { byID[$0.assetID]?.mediaCreatedAtMs }
            .map { calendar.component(.year, from: Date(timeIntervalSince1970: Double($0) / 1_000)) }

        XCTAssertEqual(project.shots.count, TimeStoryConstants.maximumShots)
        XCTAssertLessThanOrEqual(years.filter { $0 == 2024 }.count, 8)
        XCTAssertGreaterThanOrEqual(years.filter { $0 == 2025 }.count, 4)
        XCTAssertGreaterThanOrEqual(years.filter { $0 == 2026 }.count, 4)
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

    func testNativeStoryPreservesRotatedVideoMotionDirection() async throws {
        let root = try temporaryDirectory("native-rotated-story")
        let source = root.appendingPathComponent("rotated.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: source,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 128, ty: 0))
        let sourceAsset = AVURLAsset(url: source)
        let tracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)
        XCTAssertEqual(abs(transform.b), 1, accuracy: 0.001)
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        video.mediaKind = .video; video.durationMs = 1000
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot([video]), nowMs: 1)
        project = try planner.manuallyInserting(video, in: project, nowMs: 2,
            videoClip: .init(inPointMs: 0, outPointMs: 1000, sourceDurationMs: 1000, originalAudioGain: 0))
        let output = root.appendingPathComponent("rendered.mp4")
        try await AVFoundationTimeStoryRenderer(media: FixtureMixedStoryMedia(images: [:], video: source),
            temporaryDirectory: root.appendingPathComponent("work")).render(project: project, destinationURL: output) { _ in }
        try await assertPlayableVideo(output, expectsAudio: false, expectedDuration: 1)
        func centers(_ url: URL) throws -> [CGPoint] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try [6, 21].map { frame in
                let image = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 30), actualTime: nil)
                let bitmap = NSBitmapImageRep(cgImage: image)
                var sx = 0.0, sy = 0.0, count = 0.0
                for y in stride(from: 0, to: image.height, by: 2) {
                    for x in stride(from: 0, to: image.width, by: 2) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent > 0.85, color.greenComponent > 0.85, color.blueComponent > 0.85 {
                            sx += Double(x); sy += Double(y); count += 1
                        }
                    }
                }
                XCTAssertGreaterThan(count, 10)
                return CGPoint(x: sx / max(1, count), y: sy / max(1, count))
            }
        }
        let expected = try centers(source), actual = try centers(output)
        XCTAssertLessThan(abs(actual[1].x - actual[0].x), 10)
        XCTAssertGreaterThan(abs(actual[1].y - actual[0].y), 100)
        XCTAssertGreaterThan((actual[1].y - actual[0].y) * (expected[1].y - expected[0].y), 0)
        if let evidence = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: evidence)
            try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("native-rotation-source.mp4"))
            try FileManager.default.copyItem(at: output, to: directory.appendingPathComponent("native-rotation-result.mp4"))
            try writeJSON(["sourceCenters": expected.map { [$0.x, $0.y] }, "outputCenters": actual.map { [$0.x, $0.y] }],
                          to: directory.appendingPathComponent("native-rotation-centers.json"))
        }
    }

    func testMixedStoryRendersMovingMutedVideoInsteadOfPoster() async throws {
        let root = try temporaryDirectory("mixed-story-motion")
        let photo = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 2))
        video.mediaKind = .video; video.durationMs = 1000
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot([photo, video]), nowMs: 1)
        project.showsProjectTitle = false
        project = try planner.manuallyInserting(photo, in: project, nowMs: 2)
        project.shots[0].durationSeconds = 0.5
        project = try planner.manuallyInserting(video, in: project, nowMs: 3,
            videoClip: .init(inPointMs: 0, outPointMs: 1000, sourceDurationMs: 1000, originalAudioGain: 0))
        let fixture = root.appendingPathComponent("moving.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: fixture)
        let renderer = AVFoundationTimeStoryRenderer(media: FixtureMixedStoryMedia(
            images: [photo.assetID: try edgeMarkedPNG(width: 300, height: 200)], video: fixture),
            temporaryDirectory: root.appendingPathComponent("work"))
        let output = root.appendingPathComponent("mixed.mp4")
        try await renderer.render(project: project, destinationURL: output) { _ in }
        let timeline = try TimeStoryTimeline.normalize(project: project, allowsVideoClips: true)
        try await assertPlayableVideo(output, expectsAudio: false, expectedDuration: timeline.durationSeconds)
        let segment = try XCTUnwrap(timeline.segments.first { $0.shotID == project.shots[1].id })
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        func centroid(_ frame: Int) throws -> Double {
            let image = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 30), actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var total = 0.0, count = 0.0
            for y in stride(from: image.height / 4, to: image.height * 3 / 4, by: 4) {
                for x in stride(from: 0, to: image.width, by: 4) {
                    if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       c.redComponent > 0.85, c.greenComponent > 0.85, c.blueComponent > 0.85 {
                        total += Double(x); count += 1
                    }
                }
            }
            XCTAssertGreaterThan(count, 10)
            return total / max(1, count)
        }
        XCTAssertGreaterThan(abs(try centroid(segment.startFrame + 10) - centroid(segment.startFrame + 24)), 5,
                             "Moving fixture must not become one repeated poster")
        project.shots[1].videoClip?.originalAudioGain = 1
        let noAudio = root.appendingPathComponent("source-without-audio.mp4")
        try await renderer.render(project: project, destinationURL: noAudio) { _ in }
        try await assertPlayableVideo(noAudio, expectsAudio: false, expectedDuration: timeline.durationSeconds)
    }

    func testVideoStoryOriginalAudioGainMuteAndMusicPreserveSound() async throws {
        let root = try temporaryDirectory("story-original-audio")
        let silent = root.appendingPathComponent("moving.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: silent)
        let tone = root.appendingPathComponent("tone.wav")
        try writeSineWave(to: tone, seconds: 1)
        let composition = AVMutableComposition()
        let sourceVideoAsset = AVURLAsset(url: silent)
        let videoTracks = try await sourceVideoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let sourceAudioAsset = AVURLAsset(url: tone)
        let audioTracks = try await sourceAudioAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audioTrack, at: .zero)
        let source = root.appendingPathComponent("source.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        exporter.timeRange = range
        do { try await exporter.export(to: source, as: .mp4) }
        catch { throw TimeStoryError.renderingFailed("Fixture source export: \(error)") }
        withExtendedLifetime([sourceVideoAsset, sourceAudioAsset]) {}
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        video.mediaKind = .video; video.durationMs = 1000
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot([video]), nowMs: 1)
        project.showsProjectTitle = false
        project = try planner.manuallyInserting(video, in: project, nowMs: 2,
            videoClip: .init(inPointMs: 200, outPointMs: 800, sourceDurationMs: 1000))
        let renderer = AVFoundationTimeStoryRenderer(media: FixtureMixedStoryMedia(images: [:], video: source),
            temporaryDirectory: root.appendingPathComponent("work"))
        let full = root.appendingPathComponent("original.mp4")
        do { try await renderer.render(project: project, destinationURL: full) { _ in } }
        catch { throw TimeStoryError.renderingFailed("Original audio render: \(error)") }
        try await assertPlayableVideo(full, expectsAudio: true, expectedDuration: 0.6)
        let fullRMS = try await storyAudioRMS(full)
        XCTAssertGreaterThan(fullRMS, 0.01)
        project.shots[0].videoClip?.originalAudioGain = 0.25
        let quarter = root.appendingPathComponent("quarter.mp4")
        try await renderer.render(project: project, destinationURL: quarter) { _ in }
        let quarterRMS = try await storyAudioRMS(quarter)
        XCTAssertTrue((0.18...0.32).contains(quarterRMS / fullRMS))
        project.shots[0].videoClip?.originalAudioGain = 0
        let muted = root.appendingPathComponent("muted.mp4")
        try await renderer.render(project: project, destinationURL: muted) { _ in }
        let muteRMS = try await storyAudioRMS(muted)
        XCTAssertEqual(muteRMS, 0)
        project.shots[0].videoClip?.originalAudioGain = 1
        project.music = TimeStoryMusicSelection(displayName: "tone", filePath: tone.path, securityScopedBookmark: nil, volume: 0)
        let mixed = root.appendingPathComponent("original-and-muted-music.mp4")
        try await renderer.render(project: project, destinationURL: mixed) { _ in }
        let mixedRMS = try await storyAudioRMS(mixed)
        XCTAssertTrue((0.8...1.2).contains(mixedRMS / fullRMS), "Adding music must not drop original audio")
        project.music?.volume = 0.25
        let audible = root.appendingPathComponent("original-and-music.mp4")
        try await renderer.render(project: project, destinationURL: audible) { _ in }
        let audibleRMS = try await storyAudioRMS(audible)
        XCTAssertGreaterThan(abs(audibleRMS - mixedRMS), fullRMS * 0.05)
        if let directory = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in [source, full, quarter, muted, mixed, audible] {
                try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
            }
            let measurements = ["fullRMS": fullRMS, "quarterRMS": quarterRMS, "muteRMS": muteRMS,
                "originalWithMutedMusicRMS": mixedRMS, "originalWithMusicRMS": audibleRMS]
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("measurements.json"))
        }
    }

    private func storyAudioRMS(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw TimeStoryError.renderingFailed("audio reader") }
        var energy = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            XCTAssertEqual(status, noErr)
            bytes.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: size - 3, by: 4) {
                    let value = Double(raw.loadUnaligned(fromByteOffset: offset, as: Float.self))
                    energy += value * value; count += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(count, 0)
        return sqrt(energy / Double(max(1, count)))
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
        let silentAsset = AVURLAsset(url: silent)
        let silentTracks = try await silentAsset.loadTracks(withMediaType: .video)
        let silentTrack = try XCTUnwrap(silentTracks.first)
        let reader = try AVAssetReader(asset: silentAsset)
        let trackOutput = AVAssetReaderTrackOutput(track: silentTrack, outputSettings: nil)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        var videoSamples = 0
        while let buffer = trackOutput.copyNextSampleBuffer() {
            videoSamples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(videoSamples, project.timelineFrameCount)
        try await assertFourEdgesVisibleThroughoutPhotos(silent, project: project)

        let music = root.appendingPathComponent("tone.wav")
        try writeSineWave(to: music, seconds: 1)
        project.music = TimeStoryMusicSelection(
            displayName: "tone.wav",
            filePath: music.path,
            securityScopedBookmark: nil
        )
        project.shots[0].presentationMode = .aspectFill
        project.shots[1].presentationMode = .aspectFitBlack
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

    func testLegacyCompletedResultReopensOfflineWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMAGEALL_LEGACY_RESULT_ROOT"] else {
            throw XCTSkip("Requires a real completed synthetic legacy task")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let evidence = try jsonObject(at: root.appendingPathComponent("acceptance.json"))
        let published = try XCTUnwrap(evidence["result"] as? [String: Any])
        let taskID = try XCTUnwrap(published["taskID"] as? String)
        let client = makeOpenMontageClient(root: root, projectAssetImages: [:], now: Date())
        let capability = await client.capability()
        XCTAssertNotEqual(capability.state, .ready)
        let snapshot = try await client.task(taskID: taskID)
        XCTAssertEqual(snapshot.phase, .succeeded)
        let result = try await client.verifiedResult(taskID: taskID)
        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.totalFrames, 30)
        try await assertPlayableVideo(result.fileURL, expectsAudio: false, expectedDuration: 1)
        let bytes = try Data(contentsOf: result.fileURL)
        defer { try? bytes.write(to: result.fileURL) }
        try Data("changed synthetic result".utf8).write(to: result.fileURL)
        let reopened = makeOpenMontageClient(root: root, projectAssetImages: [:], now: Date())
        do { _ = try await reopened.verifiedResult(taskID: taskID); XCTFail("Changed output was trusted") }
        catch let error as OpenMontageTaskError {
            guard case .resultValidationFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTaskReaderAcceptsLegacySchemaAndRejectsMismatchedIdentity() async throws {
        let root = try temporaryDirectory("legacy-schema-reader")
        let now = Date()
        try writeOpenMontageExecutorFixture(at: root, now: now)
        let first = UUID(), second = UUID()
        let client = makeOpenMontageClient(root: root, projectAssetImages: [
            first: try pngData(color: .red, portrait: false), second: try pngData(color: .blue, portrait: false)], now: now)
        let submitted = try await client.submit(project: renderProject(first: first, second: second), aspect: .landscape) { _ in }
        let submission = root.appendingPathComponent("tasks/\(submitted.taskID)/submission")
        for name in ["task.json", "complete.json"] {
            let url = submission.appendingPathComponent(name)
            var json = try jsonObject(at: url)
            var package = try XCTUnwrap(json["storyPackage"] as? [String: Any])
            package["schemaVersion"] = OpenMontageContract.legacyStorySchemaVersion
            package["schemaSHA256"] = OpenMontageContract.legacyStorySchemaSHA256
            json["storyPackage"] = package
            try writeJSON(json, to: url)
        }
        let storyURL = submission.appendingPathComponent("package/story.json")
        var story = try jsonObject(at: storyURL)
        story["schemaVersion"] = OpenMontageContract.legacyStorySchemaVersion
        try writeJSON(story, to: storyURL)
        let reader = makeOpenMontageClient(root: root, projectAssetImages: [:], now: now)
        let restored = try await reader.task(taskID: submitted.taskID)
        XCTAssertEqual(restored.phase, .waitingForExecutor)
        // This checks parsing/identity before execution, not a forged successful result.
        story["schemaVersion"] = "0.2"
        try writeJSON(story, to: storyURL)
        do { _ = try await reader.task(taskID: submitted.taskID); XCTFail("Mixed envelope/body versions accepted") }
        catch let error as OpenMontageTaskError {
            guard case .protocolViolation = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAutomaticMixedStoryPreservesDistinctEditedClipsWhenReplanning() throws {
        let photo = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        var video = candidate(UUID().uuidString, time: timestamp(2025, 1, 1))
        video.mediaKind = .video; video.durationMs = 1000
        let snapshot = makeSnapshot([photo, video])
        let planner = TimeStoryPlanner()
        let automatic = try planner.makeProject(snapshot: snapshot, nowMs: 1)
        let automaticClip = try XCTUnwrap(automatic.shots.first { $0.assetID == video.assetID }?.videoClip)
        XCTAssertEqual(automaticClip.inPointMs, 0)
        XCTAssertEqual(automaticClip.outPointMs, 1000)
        var manual = planner.makeFreeformProject(snapshot: snapshot, nowMs: 1)
        manual = try planner.manuallyInserting(video, in: manual, nowMs: 2,
            videoClip: .init(inPointMs: 0, outPointMs: 500, sourceDurationMs: 1000, originalAudioGain: 0))
        manual = try planner.manuallyInserting(video, in: manual, nowMs: 3,
            videoClip: .init(inPointMs: 500, outPointMs: 1000, sourceDurationMs: 1000, originalAudioGain: 0.25))
        let rebuilt = try planner.makeProject(snapshot: snapshot, nowMs: 4, existing: manual)
        for shot in manual.shots {
            XCTAssertEqual(rebuilt.shots.first { $0.id == shot.id }?.videoClip, shot.videoClip)
        }
        let references = rebuilt.chapters.flatMap(\.shotIDs)
        XCTAssertEqual(Set(references), Set(rebuilt.shots.map(\.id)))
        XCTAssertEqual(references.count, rebuilt.shots.count)
        _ = try TimeStoryTimeline.normalize(project: rebuilt, allowsVideoClips: true)
        video.durationMs = 900
        XCTAssertThrowsError(try planner.makeProject(snapshot: makeSnapshot([photo, video]), nowMs: 5, existing: manual))
    }

    func testMixedStoryRealExecutorRoundTripWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["IMAGEALL_MIXED_EXECUTOR_ROOT"] else {
            throw XCTSkip("Requires an independently running synthetic task executor")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let inputs = root.appendingPathComponent("swift-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: false)
        let photo = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 2))
        video.mediaKind = .video; video.durationMs = 1000
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot([photo, video]), nowMs: 1)
        project.showsProjectTitle = false
        project = try planner.manuallyInserting(photo, in: project, nowMs: 2)
        project.shots[0].durationSeconds = 0.5
        project = try planner.manuallyInserting(video, in: project, nowMs: 3,
            videoClip: .init(inPointMs: 200, outPointMs: 800, sourceDurationMs: 1000, originalAudioGain: 0))
        let source = inputs.appendingPathComponent("source.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: source)
        let client = FileOpenMontageStoryTaskClient(rootProvider: FixtureOpenMontageRootProvider(root: root),
            packageExporter: StoryRenderPackageExporter(media: FixtureMixedStoryMedia(
                images: [photo.assetID: try edgeMarkedPNG(width: 300, height: 200)], video: source),
                validator: PassingStoryValidator()), installationID: "synthetic-mixed-roundtrip", applicationVersion: "tests")
        let submitted = try await client.submit(project: project, aspect: .landscape) { _ in }
        var current = submitted
        let deadline = Date().addingTimeInterval(180)
        while !current.phase.isTerminal && Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            current = try await client.task(taskID: submitted.taskID)
        }
        guard current.phase == .succeeded else {
            if !current.phase.isTerminal { _ = try? await client.requestCancellation(taskID: submitted.taskID) }
            XCTFail("Real mixed task did not succeed: \(current.phase) \(current.detail ?? "")")
            return
        }
        let verified = try await client.verifiedResult(taskID: submitted.taskID)
        let timeline = try TimeStoryTimeline.normalize(project: project, allowsVideoClips: true)
        XCTAssertEqual(verified.totalFrames, timeline.totalFrames)
        XCTAssertEqual(verified.fileSHA256, try fileSHA256(verified.fileURL))
        XCTAssertEqual(verified.width, 1920)
        XCTAssertEqual(verified.height, 1080)
        try await assertPlayableVideo(verified.fileURL, expectsAudio: false, expectedDuration: timeline.durationSeconds)
        try writeJSON(["taskID": submitted.taskID, "resultPath": verified.fileURL.path,
                       "sha256": verified.fileSHA256, "frames": verified.totalFrames,
                       "width": verified.width, "height": verified.height],
                      to: root.appendingPathComponent("swift-roundtrip-verified.json"))
    }

    func testMixedStoryPackageFreezesVideoAndPreservesIndependentClipRanges() async throws {
        let root = try temporaryDirectory("mixed-story-package")
        let photo = candidate(UUID().uuidString, time: timestamp(2024, 1, 1))
        var video = candidate(UUID().uuidString, time: timestamp(2024, 1, 2))
        video.mediaKind = .video; video.durationMs = 1000
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot([photo, video]), nowMs: 1)
        project.showsProjectTitle = false
        project = try planner.manuallyInserting(photo, in: project, nowMs: 2)
        project.shots[0].durationSeconds = 0.5
        project = try planner.manuallyInserting(video, in: project, nowMs: 3,
            videoClip: .init(inPointMs: 200, outPointMs: 800, sourceDurationMs: 1000, originalAudioGain: 0.25))
        project = try planner.manuallyInserting(video, in: project, nowMs: 4,
            videoClip: .init(inPointMs: 0, outPointMs: 500, sourceDurationMs: 1000, originalAudioGain: 0))
        let source = root.appendingPathComponent("source.mp4")
        try await FixtureMixedStoryMedia.makeMovingVideo(at: source)
        let exporter = StoryRenderPackageExporter(media: FixtureMixedStoryMedia(
            images: [photo.assetID: try edgeMarkedPNG(width: 300, height: 200)], video: source),
            validator: PassingStoryValidator())
        let destination = root.appendingPathComponent("mixed.storyrenderpackage")
        _ = try await exporter.export(project: project, aspect: .landscape, destinationURL: destination) { _ in }
        let document = try packageDocument(at: destination)
        XCTAssertEqual(document.schemaVersion, "0.2")
        XCTAssertEqual(document.assets.count, 2)
        let resource = try XCTUnwrap(document.assets.first { $0.video != nil })
        XCTAssertEqual(resource.mediaType, "video/mp4")
        XCTAssertEqual(resource.video?.durationMs, 1000)
        XCTAssertEqual(resource.video?.hasAudio, false)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(resource.relativePath)),
                       try Data(contentsOf: source))
        let clips = document.chapters.flatMap(\.shots).filter { $0.kind == "video" }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map(\.assetID), [resource.assetID, resource.assetID])
        XCTAssertEqual(clips.compactMap { $0.videoClip?.inFrame }, [6, 0])
        XCTAssertEqual(clips.compactMap { $0.videoClip?.outFrame }, [24, 15])
        XCTAssertEqual(clips.compactMap { $0.videoClip?.originalAudioGain }, [0.25, 0])
        XCTAssertTrue(clips.allSatisfy { $0.motion == nil })
        XCTAssertEqual(document.export.totalFrames,
                       try TimeStoryTimeline.normalize(project: project, allowsVideoClips: true).totalFrames)
        if let evidence = ProcessInfo.processInfo.environment["IMAGEALL_VIDEO_EVIDENCE_DIR"] {
            let saved = URL(fileURLWithPath: evidence).appendingPathComponent("swift-mixed.storyrenderpackage")
            try FileManager.default.copyItem(at: destination, to: saved)
        }
        let before = try Data(contentsOf: destination.appendingPathComponent("story.json"))
        project.shots[1].videoClip?.sourceDurationMs = 999
        do {
            _ = try await exporter.export(project: project, aspect: .landscape, destinationURL: destination) { _ in }
            XCTFail("A changed video duration must not replace the published package")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("story.json")), before)
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
        project.typography = StoryTypography(family: "Songti SC", titleSize: 72, captionSize: 40, weight: 700)
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

        XCTAssertEqual(landscapeDocument.export.template.fontFamily, "Songti SC")
        XCTAssertEqual(landscapeDocument.export.template.captionFontSize, 40)
        XCTAssertEqual(landscapeDocument.export.template.titleFontSize, 72)
        XCTAssertEqual(landscapeDocument.export.template.fontWeight, 700)
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

    func testOpenMontageSubmissionPublishesFrozenV11EnvelopeAndRejectsDuplicate() async throws {
        let root = try temporaryDirectory("openmontage-submit")
        let fixedNow = Date(timeIntervalSince1970: 1_789_747_200)
        try writeOpenMontageExecutorFixture(at: root, now: fixedNow)
        let first = UUID()
        let second = UUID()
        let project = renderProject(first: first, second: second)
        let client = makeOpenMontageClient(
            root: root,
            projectAssetImages: [
                first: try edgeMarkedPNG(width: 1_200, height: 700),
                second: try edgeMarkedPNG(width: 700, height: 1_200),
            ],
            now: fixedNow
        )

        let snapshot = try await client.submit(project: project, aspect: .landscape) { _ in }
        let submission = root.appendingPathComponent("tasks/\(snapshot.taskID)/submission")
        let task = try jsonObject(at: submission.appendingPathComponent("task.json"))
        let completion = try jsonObject(at: submission.appendingPathComponent("complete.json"))

        XCTAssertEqual(task["protocolVersion"] as? String, "1.1")
        XCTAssertEqual(task["taskID"] as? String, snapshot.taskID)
        XCTAssertNil(task["command"])
        XCTAssertNil(task["executable"])
        XCTAssertNil(task["interpreter"])
        XCTAssertEqual(completion["protocolVersion"] as? String, "1.1")
        XCTAssertEqual(completion["deliveryID"] as? String, snapshot.taskID)
        XCTAssertEqual(completion["taskID"] as? String, snapshot.taskID)
        XCTAssertEqual(completion["projectID"] as? String, snapshot.projectID)
        XCTAssertEqual(completion["projectRevision"] as? String, snapshot.projectRevision)
        XCTAssertEqual(completion["status"] as? String, "complete")
        XCTAssertEqual(
            (completion["producer"] as? [String: Any])?["application"] as? String,
            "ImageAll"
        )
        XCTAssertEqual(
            (completion["storyPackage"] as? [String: Any])?["entrypoint"] as? String,
            "package/story.json"
        )
        XCTAssertEqual(
            (completion["storyPackage"] as? [String: Any])?["schemaSHA256"] as? String,
            StoryRenderPackageExporter.schemaSHA256
        )
        let entries = try XCTUnwrap(completion["files"] as? [[String: Any]])
        let manifest = try entries.map { entry -> String in
            let path = try XCTUnwrap(entry["path"] as? String)
            let size = try XCTUnwrap(entry["sizeBytes"] as? Int)
            let sha256 = try XCTUnwrap(entry["sha256"] as? String)
            let file = submission.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: file).count, size)
            XCTAssertEqual(try fileSHA256(file), sha256)
            return "\(sha256)  \(size)  \(path)\n"
        }.joined()
        XCTAssertEqual(
            SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined(),
            completion["manifestSHA256"] as? String
        )
        XCTAssertFalse(entries.contains { ($0["path"] as? String) == "complete.json" })

        do {
            _ = try await client.submit(project: project, aspect: .portrait) { _ in }
            XCTFail("a second click must not publish another unfinished task")
        } catch let error as OpenMontageTaskError {
            XCTAssertEqual(error, .taskAlreadyActive)
        }
        let taskDirectories = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("tasks"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(taskDirectories.count, 1)
    }

    func testOpenMontageLifecycleCancelRecoveryAndRevisionIsolation() async throws {
        let root = try temporaryDirectory("openmontage-lifecycle")
        let fixedNow = Date(timeIntervalSince1970: 1_789_747_200)
        try writeOpenMontageExecutorFixture(at: root, now: fixedNow)
        let first = UUID()
        let second = UUID()
        let images = [
            first: try edgeMarkedPNG(width: 1_200, height: 700),
            second: try edgeMarkedPNG(width: 700, height: 1_200),
        ]
        let project = renderProject(first: first, second: second)
        let client = makeOpenMontageClient(
            root: root,
            projectAssetImages: images,
            now: fixedNow
        )
        let submitted = try await client.submit(project: project, aspect: .landscape) { _ in }
        let taskRoot = root.appendingPathComponent("tasks/\(submitted.taskID)")
        let completion = try jsonObject(at: taskRoot.appendingPathComponent("submission/complete.json"))
        let digest = try XCTUnwrap(completion["manifestSHA256"] as? String)
        try writeOpenMontageStatus(
            at: taskRoot,
            snapshot: submitted,
            digest: digest,
            sequence: 1,
            state: "running",
            stage: "rendering",
            progress: 0.4,
            terminal: false,
            now: fixedNow
        )
        let running = try await client.task(taskID: submitted.taskID)
        XCTAssertEqual(running.phase, .rendering)
        XCTAssertEqual(running.progress, 0.4)

        _ = try await client.requestCancellation(taskID: submitted.taskID)
        let cancel = try jsonObject(at: taskRoot.appendingPathComponent("requests/cancel.json"))
        XCTAssertEqual(cancel["taskID"] as? String, submitted.taskID)
        XCTAssertNotNil(cancel["requestID"] as? String)
        try writeOpenMontageStatus(
            at: taskRoot,
            snapshot: submitted,
            digest: digest,
            sequence: 2,
            state: "cancelled",
            stage: "terminal",
            progress: 0.4,
            terminal: true,
            error: [
                "code": "RENDER_CANCELLED",
                "stage": "rendering",
                "message": "render was cancelled; pending output was removed",
                "retryable": false,
            ],
            now: fixedNow
        )
        let cancelled = try await client.task(taskID: submitted.taskID)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.result)
        XCTAssertEqual(cancelled.detail, "取消请求已确认，没有发布成片。")

        let recoveredClient = makeOpenMontageClient(
            root: root,
            projectAssetImages: images,
            now: fixedNow
        )
        let recovered = try await recoveredClient.latestTask(projectID: project.id)
        XCTAssertEqual(recovered?.taskID, submitted.taskID)
        XCTAssertEqual(recovered?.phase, .cancelled)

        try writeOpenMontageStatus(
            at: taskRoot,
            snapshot: submitted,
            digest: digest,
            sequence: 3,
            state: "running",
            stage: "rendering",
            progress: 0.9,
            terminal: false,
            now: fixedNow
        )
        let afterLateProgress = try await client.task(taskID: submitted.taskID)
        XCTAssertEqual(afterLateProgress.phase, .cancelled)

        // Restore the executor-owned terminal status before publishing a new revision.
        try writeOpenMontageStatus(
            at: taskRoot,
            snapshot: submitted,
            digest: digest,
            sequence: 2,
            state: "cancelled",
            stage: "terminal",
            progress: 0.4,
            terminal: true,
            now: fixedNow
        )
        let oldCompletionHash = try fileSHA256(taskRoot.appendingPathComponent("submission/complete.json"))
        var edited = project
        edited.title = "编辑后的新版本"
        edited.updatedAtMs += 1
        let newer = try await client.submit(project: edited, aspect: .portrait) { _ in }
        XCTAssertNotEqual(newer.taskID, submitted.taskID)
        XCTAssertNotEqual(newer.projectRevision, submitted.projectRevision)
        XCTAssertEqual(
            try fileSHA256(taskRoot.appendingPathComponent("submission/complete.json")),
            oldCompletionHash,
            "new task publication must not overwrite the old task"
        )
        let newerRoot = root.appendingPathComponent("tasks/\(newer.taskID)")
        let newerCompletion = try jsonObject(at: newerRoot.appendingPathComponent("submission/complete.json"))
        try writeOpenMontageStatus(
            at: newerRoot,
            snapshot: newer,
            digest: try XCTUnwrap(newerCompletion["manifestSHA256"] as? String),
            sequence: 1,
            state: "failed",
            stage: "terminal",
            progress: 0.9,
            terminal: true,
            error: [
                "code": "RESULT_VERIFICATION_FAILED",
                "stage": "verification",
                "message": "adapter artifact path is unsafe",
                "retryable": false,
            ],
            now: fixedNow
        )
        let failed = try await client.task(taskID: newer.taskID)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.detail, "成片未通过执行器检查。请查看本地任务记录；原生制作仍可使用。")
    }

    func testOpenMontageStaleExecutorDoesNotPublishPartialTask() async throws {
        let root = try temporaryDirectory("openmontage-offline")
        let fixedNow = Date(timeIntervalSince1970: 1_789_747_200)
        try writeOpenMontageExecutorFixture(
            at: root,
            now: fixedNow.addingTimeInterval(-30)
        )
        let first = UUID()
        let second = UUID()
        let project = renderProject(first: first, second: second)
        let client = makeOpenMontageClient(
            root: root,
            projectAssetImages: [
                first: try edgeMarkedPNG(width: 1_200, height: 700),
                second: try edgeMarkedPNG(width: 700, height: 1_200),
            ],
            now: fixedNow
        )

        let capability = await client.capability()
        XCTAssertEqual(capability.state, .offline)
        do {
            _ = try await client.submit(project: project, aspect: .landscape) { _ in }
            XCTFail("stale executor unexpectedly accepted a task")
        } catch let error as OpenMontageTaskError {
            guard case .executorOffline = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks").path))
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

    func testManualCandidateAdditionKeepsStoryChronologicalAndEditable() throws {
        let first = UUID(), second = UUID(), middle = UUID()
        var project = renderProject(first: first, second: second)
        let candidate = candidate(middle.uuidString, time: timestamp(2022, 1, 1))
        project.candidateSnapshot = makeSnapshot(project.candidateSnapshot.candidates + [candidate])
        let planner = TimeStoryPlanner()

        XCTAssertEqual(planner.addableCandidates(in: project).map(\.assetID), [middle])
        let updated = try planner.appending(candidate, to: project, nowMs: 42)
        XCTAssertEqual(updated.shots.map(\.assetID), [first, middle, second])
        XCTAssertEqual(updated.chapters[0].shotIDs, updated.shots.map(\.id))
        XCTAssertEqual(updated.shots[1].caption, "")
        XCTAssertFalse(updated.shots[1].isLocked)
        XCTAssertEqual(updated.updatedAtMs, 42)
        XCTAssertEqual(updated.readiness.matchingCount, 3)
        XCTAssertThrowsError(try planner.appending(candidate, to: updated, nowMs: 43))
    }

    @MainActor
    func testCreativeProgressLocksMutationsAndCancellationRestoresEditing() async throws {
        let root = try temporaryDirectory("creative-input-lock")
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        let media = CountingStoryThumbnailLoader(data: try pngData(color: .red, portrait: false))
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let roots = FixtureOpenMontageRootProvider(root: root)
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(database: database, query: GRDBAssetCatalogQueryRepository(database: database)),
            planner: TimeStoryPlanner(), store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: PassingStoryValidator(), renderer: AVFoundationTimeStoryRenderer(media: media, temporaryDirectory: root),
            packageExporter: exporter, openMontageTasks: FileOpenMontageStoryTaskClient(rootProvider: roots, packageExporter: exporter, installationID: "fixture"),
            creativeRootProvider: roots, media: media, clock: SystemJobClock())
        let receipt = StoryCreativeReceipt(requestID: "creative-" + UUID().uuidString.lowercased(), requestSHA256: String(repeating: "a", count: 64), baseFingerprint: "test", aspect: .landscape)
        project.creativeReceipt = receipt
        let directory = root.appendingPathComponent("creative/requests/" + receipt.requestID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"phase":"calling-model","message":"正在生成合成方案"}"#.utf8).write(to: directory.appendingPathComponent("auto-status.json"))
        let model = TimeStoryWorkspaceModel(verificationRuntime: runtime,
            tag: TagListItem(id: project.subjectTagID, displayName: project.subjectTagDisplayName, state: .active), project: project, thumbnails: [:])
        model.refreshCreativeRequest()
        XCTAssertTrue(model.isCreativeRunning)
        XCTAssertTrue(model.isInputLocked)
        let before = model.project
        let id = project.shots[0].id
        model.setCaption(id, caption: "不应写入")
        model.setDuration(id, seconds: 8)
        model.setCreativeIntent("不应改动")
        model.moveShot(id, before: nil)
        model.editShots([id], remove: true)
        model.allowCreativeOptimization([id])
        model.undo()
        XCTAssertEqual(model.project, before)
        model.cancelCreativeRequest()
        XCTAssertFalse(model.isCreativeRunning)
        XCTAssertFalse(model.isInputLocked)
        model.setCaption(id, caption: "取消后允许编辑")
        XCTAssertEqual(model.project?.shots[0].caption, "取消后允许编辑")
    }

    @MainActor
    func testMaterialThumbnailsUseSmallImageRouteAndCoalesceRequests() async throws {
        let root = try temporaryDirectory("thumbnail-route")
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let first = UUID(), second = UUID()
        let project = renderProject(first: first, second: second)
        let media = CountingStoryThumbnailLoader(data: try pngData(color: .red, portrait: false))
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let roots = FixtureOpenMontageRootProvider(root: root)
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(database: database, query: GRDBAssetCatalogQueryRepository(database: database)),
            planner: TimeStoryPlanner(), store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: PassingStoryValidator(), renderer: AVFoundationTimeStoryRenderer(media: media, temporaryDirectory: root),
            packageExporter: exporter, openMontageTasks: FileOpenMontageStoryTaskClient(rootProvider: roots, packageExporter: exporter, installationID: "fixture"),
            creativeRootProvider: roots, media: media, clock: SystemJobClock())
        let model = TimeStoryWorkspaceModel(verificationRuntime: runtime,
            tag: TagListItem(id: project.subjectTagID, displayName: project.subjectTagDisplayName, state: .active), project: project, thumbnails: [:])
        let candidate = try XCTUnwrap(project.candidateSnapshot.candidates.first)
        async let firstLoad: Void = model.loadCandidateThumbnail(candidate)
        async let secondLoad: Void = model.loadCandidateThumbnail(candidate)
        _ = await (firstLoad, secondLoad)
        await model.loadCandidateThumbnail(candidate)
        let counts = await media.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
        XCTAssertNotNil(model.candidateThumbnails[candidate.assetID])
        let selected = Set(project.shots.map(\.id))
        model.editShots(selected, duration: 5, mode: .aspectFill, locked: true)
        XCTAssertTrue(model.project!.shots.allSatisfy { $0.durationSeconds == 5 && $0.presentationMode == .aspectFill && $0.isLocked })
        model.undo()
        XCTAssertEqual(model.project, project, "one undo restores the whole batch")
        model.redo()
        XCTAssertTrue(model.project!.shots.allSatisfy { $0.presentationMode == .aspectFill })
        try runtime.store.save(model.project!)
        XCTAssertEqual(try runtime.store.load(project.id).shots, model.project!.shots)
        model.editShots(selected, remove: true)
        XCTAssertTrue(model.project!.shots.isEmpty)
        XCTAssertTrue(model.project!.chapters.isEmpty)
        model.undo()
        XCTAssertEqual(model.project!.shots.count, 2)
        _ = try TimeStoryTimeline.normalize(project: model.project!)
        model.moveShots([model.project!.shots[0].id], before: nil)
        XCTAssertEqual(model.project!.shots.map(\.assetID), [second, first])
        model.undo()
        XCTAssertEqual(model.project!.shots.map(\.assetID), [first, second])
        model.undo()
        XCTAssertEqual(model.project, project)
        model.setCreativeIntent("已编辑")
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.project?.creativeIntent, project.creativeIntent)
        model.redo()
        XCTAssertEqual(model.project?.creativeIntent, "已编辑")
    }

    func testOpenMontageAuthorizationFailureIsDistinctFromOffline() async throws {
        let inspector = OpenMontageTaskDirectoryInspector(rootProvider: DeniedStoryRootProvider())
        let capability = await inspector.capability()
        XCTAssertEqual(capability.state, .authorizationRequired)
        let media = FixtureStoryMediaLoader(images: [:])
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let client = FileOpenMontageStoryTaskClient(rootProvider: DeniedStoryRootProvider(), packageExporter: exporter, installationID: "fixture")
        let actual = await client.capability()
        XCTAssertEqual(actual.state, .authorizationRequired)
    }

    func testFreeformExceedsTemplateLimitAndPersistsOptionalTitleCards() throws {
        let candidates = (0..<30).map { _ in candidate(UUID().uuidString, time: nil) }
        let planner = TimeStoryPlanner()
        var project = planner.makeFreeformProject(snapshot: makeSnapshot(candidates), nowMs: 1)
        XCTAssertTrue(project.shots.isEmpty)
        XCTAssertEqual(project.isFreeform, true)
        XCTAssertEqual(project.title, project.subjectTagDisplayName)
        for candidate in candidates { project = try planner.manuallyInserting(candidate, in: project, nowMs: 2) }
        XCTAssertEqual(project.shots.count, 30)
        let plain = try TimeStoryTimeline.normalize(project: project)
        XCTAssertEqual(plain.segments.count, 30)
        project.showsProjectTitle = true
        project.showsChapterTitles = true
        XCTAssertEqual(Array(try TimeStoryTimeline.normalize(project: project).segments.map(\.kind).prefix(2)), [.projectTitle, .photo])
        XCTAssertEqual(try TimeStoryTimeline.normalize(project: project).segments.count, 31)
        project.chapters[0].title = "音乐节现场"
        XCTAssertEqual(try TimeStoryTimeline.normalize(project: project).segments.count, 32)
        let store = TimeStoryProjectStore(applicationSupportDirectory: try temporaryDirectory("freeform"))
        try store.save(project)
        XCTAssertEqual(try store.load(project.id), project)
        XCTAssertThrowsError(try planner.manuallyInserting(candidates[0], in: project, nowMs: 3))
    }

    func testManualMontageAcrossChaptersRoundTripsAndRejectsForeignCandidates() throws {
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        let chapterID = UUID()
        project.shots[1].chapterID = chapterID
        project.chapters[0].shotIDs = [project.shots[0].id]
        project.chapters.append(TimeStoryChapter(id: chapterID, title: "另一章节", shotIDs: [project.shots[1].id], isUserEdited: false))
        let extra = candidate(UUID().uuidString, time: nil, place: "新地点")
        project.candidateSnapshot = makeSnapshot(project.candidateSnapshot.candidates + [extra])
        let planner = TimeStoryPlanner()
        let inserted = try planner.manuallyInserting(extra, in: project, nowMs: 41)
        XCTAssertEqual(inserted.shots.count, 3)
        XCTAssertFalse(inserted.shots[2].isLocked)
        XCTAssertFalse(inserted.shots[2].protectsCaption)
        XCTAssertFalse(inserted.shots[2].protectsDuration)
        XCTAssertNoThrow(try TimeStoryTimeline.normalize(project: inserted))
        let moved = try planner.moving(inserted.shots[2].id, before: inserted.shots[0].id, in: inserted, nowMs: 42)
        XCTAssertEqual(moved.shots.first?.assetID, extra.assetID)
        XCTAssertEqual(moved.chapters.flatMap(\.shotIDs), moved.shots.map(\.id))
        XCTAssertNoThrow(try TimeStoryTimeline.normalize(project: moved))
        let store = TimeStoryProjectStore(applicationSupportDirectory: try temporaryDirectory("manual-montage"))
        try store.save(moved)
        XCTAssertEqual(try store.load(moved.id), moved)
        XCTAssertThrowsError(try planner.manuallyInserting(extra, in: moved, nowMs: 43))
        XCTAssertThrowsError(try planner.manuallyInserting(candidate(UUID().uuidString, time: nil), in: moved, nowMs: 43))
        var excluded = project
        excluded.excludedAssetIDs.insert(extra.assetID)
        XCTAssertThrowsError(try planner.manuallyInserting(extra, in: excluded, nowMs: 43))
        XCTAssertThrowsError(try planner.moving(UUID(), before: nil, in: moved, nowMs: 43))
    }

    func testCreativePluginBoundedRoundTripAndStaleRejection() async throws {
        let root = try temporaryDirectory("creative").resolvingSymlinksInPath()
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        project.creativeIntent = "按时间讲述合成主体的变化"
        project.creativeTargetFrames = 300
        let media = FixtureStoryMediaLoader(images: [first: try pngData(color: .red, portrait: false), second: try pngData(color: .blue, portrait: true)])
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let plugin = StoryCreativePlugin(rootProvider: FixtureOpenMontageRootProvider(root: root), exporter: exporter, validator: PassingStoryValidator())
        let creative = root.appendingPathComponent("creative")
        try FileManager.default.createDirectory(at: creative, withIntermediateDirectories: true)
        let capability: [String: Any] = ["protocolVersion": "1.0", "profile": "editable-story-v1", "pluginID": "openmontage", "pluginVersion": "1.0.0", "planningMode": "agent-assisted", "automaticPlanning": false, "externalSendAllowed": false, "renderProtocol": "1.1", "renderPackage": "0.1"]
        try JSONSerialization.data(withJSONObject: capability).write(to: creative.appendingPathComponent("capabilities.json"))
        let receipt = try await plugin.publish(project: project, aspect: .landscape)
        project.creativeReceipt = receipt
        let directory = creative.appendingPathComponent("requests/" + receipt.requestID)
        let requestData = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        XCTAssertEqual(StoryCreativePlugin.hash(requestData), receipt.requestSHA256)
        let request = try JSONDecoder().decode(StoryCreativeRequest.self, from: requestData)
        XCTAssertFalse(request.externalSendAllowed)
        XCTAssertEqual(request.facts.count, 2)
        XCTAssertFalse(String(decoding: requestData, as: UTF8.self).contains("filePath"))
        var plan = StoryCreativePlan(protocolVersion: "1.0", profile: "editable-story-v1", requestID: receipt.requestID, requestSHA256: receipt.requestSHA256,
            pluginVersion: "1.0.0", planningMode: "agent-assisted", title: "新标题", chapters: request.chapters,
            shots: request.shots.map { .init(shotID: $0.shotID, assetID: $0.assetID, chapterID: $0.chapterID, caption: "导演字幕", durationFrames: 75,
                                            factRefs: [$0.assetID + ".captureTimeMs"], rationale: "保留时间跨度") },
            observations: ["合成素材"], uncertainties: ["未进行真人或宠物身份判断"])
        let data = try StoryCreativePlugin.encode(plan)
        let hash = StoryCreativePlugin.hash(data)
        try data.write(to: directory.appendingPathComponent("plan.json"))
        try StoryCreativePlugin.encode(["requestSHA256": receipt.requestSHA256, "planSHA256": hash]).write(to: directory.appendingPathComponent("ready.json"))
        let (loadedRequest, loadedPlan, loadedHash) = try plugin.loadPlan(receipt)
        var applied = try plugin.apply(loadedPlan, request: loadedRequest, digest: loadedHash, to: project)
        XCTAssertEqual(applied.title, "新标题")
        XCTAssertEqual(applied.shots.first?.durationSeconds, 2.5)
        XCTAssertEqual(applied.candidateSnapshot, project.candidateSnapshot, "插件观察不能修改图库事实")
        var protectedRequest = request
        protectedRequest.shots[0].captionProtected = true
        XCTAssertThrowsError(try plugin.apply(plan, request: protectedRequest, digest: loadedHash, to: project))
        var captionPlan = plan
        captionPlan.shots[0].caption = request.shots[0].caption
        XCTAssertNoThrow(try plugin.apply(captionPlan, request: protectedRequest, digest: loadedHash, to: project))
        protectedRequest.shots[0].captionProtected = false
        protectedRequest.shots[0].durationProtected = true
        XCTAssertThrowsError(try plugin.apply(plan, request: protectedRequest, digest: loadedHash, to: project))
        var durationPlan = plan
        durationPlan.shots[0].durationFrames = request.shots[0].durationFrames
        XCTAssertNoThrow(try plugin.apply(durationPlan, request: protectedRequest, digest: loadedHash, to: project))
        let store = TimeStoryProjectStore(applicationSupportDirectory: root)
        applied.shots[0].caption = "用户修改"
        try store.save(applied)
        XCTAssertEqual(try store.load(applied.id), applied)
        var edited = project
        edited.shots[0].caption = "发布后用户编辑"
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: edited))
        plan.profile = "arbitrary-atelier"
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: project))
        try plugin.cancel(receipt)
        XCTAssertTrue(try plugin.status(receipt).contains("已取消"))
        XCTAssertThrowsError(try plugin.loadPlan(receipt))
        let retry = try await plugin.publish(project: project, aspect: .portrait)
        XCTAssertNotEqual(retry.requestID, receipt.requestID)
    }

    func testAutomaticCreativeAuthorizedRoundTripAndManualEdit() async throws {
        let root = try temporaryDirectory("auto-creative").resolvingSymlinksInPath()
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        project.creativeIntent = "按时间讲述合成主体的变化"
        project.creativeTargetFrames = 300
        let media = FixtureStoryMediaLoader(images: [first: try pngData(color: .red, portrait: false), second: try pngData(color: .blue, portrait: true)])
        let exporter = StoryRenderPackageExporter(media: media, validator: PassingStoryValidator())
        let plugin = StoryCreativePlugin(rootProvider: FixtureOpenMontageRootProvider(root: root), exporter: exporter, validator: PassingStoryValidator())
        let creative = root.appendingPathComponent("creative")
        try FileManager.default.createDirectory(at: creative, withIntermediateDirectories: true)
        let capability: [String: Any] = ["protocolVersion": "1.2", "profile": "editable-story-v1", "pluginID": "openmontage", "pluginVersion": "1.2.1", "planningMode": "automatic-model", "automaticPlanning": true, "externalSendAllowed": false, "renderProtocol": "1.1", "renderPackage": "0.1"]
        try JSONSerialization.data(withJSONObject: capability).write(to: creative.appendingPathComponent("capabilities.json"))
        var oldCapability = capability
        oldCapability["pluginVersion"] = "1.2.0"
        try JSONSerialization.data(withJSONObject: oldCapability).write(to: creative.appendingPathComponent("capabilities.json"))
        do {
            _ = try await plugin.publish(project: project, aspect: .landscape, authorization: .init(endpoint: "https://example.invalid/v1/chat/completions", model: "synthetic"))
            XCTFail("Old director must be rejected before publishing")
        } catch { XCTAssertTrue(error.localizedDescription.contains("旧版本")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: creative.appendingPathComponent("requests").path))
        try JSONSerialization.data(withJSONObject: capability).write(to: creative.appendingPathComponent("capabilities.json"))
        let receipt = try await plugin.publish(project: project, aspect: .landscape, authorization: .init(endpoint: "https://example.invalid/v1/chat/completions", model: "synthetic"))
        XCTAssertTrue(try plugin.isPending(receipt))
        project.creativeReceipt = receipt
        let directory = creative.appendingPathComponent("requests/" + receipt.requestID)
        let requestData = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        XCTAssertEqual(StoryCreativePlugin.hash(requestData), receipt.requestSHA256)
        let request = try JSONDecoder().decode(StoryCreativeRequest.self, from: requestData)
        XCTAssertTrue(request.externalSendAllowed)
        XCTAssertEqual(request.modelAuthorization?.model, "synthetic")
        XCTAssertEqual(request.facts.count, 2)
        XCTAssertFalse(String(decoding: requestData, as: UTF8.self).contains("filePath"))
        var plan = StoryCreativePlan(protocolVersion: "1.2", profile: "editable-story-v1", requestID: receipt.requestID, requestSHA256: receipt.requestSHA256,
            pluginVersion: "1.0.0", planningMode: "automatic-model", title: "新标题", chapters: request.chapters,
            shots: request.shots.map { .init(shotID: $0.shotID, assetID: $0.assetID, chapterID: $0.chapterID, caption: "导演字幕", durationFrames: 75,
                                            factRefs: [$0.assetID + ".captureTimeMs"], rationale: "保留时间跨度") },
            observations: ["合成素材"], uncertainties: ["未进行真人或宠物身份判断"])
        let data = try StoryCreativePlugin.encode(plan)
        let hash = StoryCreativePlugin.hash(data)
        try data.write(to: directory.appendingPathComponent("plan.json"))
        try StoryCreativePlugin.encode(["requestSHA256": receipt.requestSHA256, "planSHA256": hash]).write(to: directory.appendingPathComponent("ready.json"))
        XCTAssertFalse(try plugin.isPending(receipt))
        let (loadedRequest, loadedPlan, loadedHash) = try plugin.loadPlan(receipt)
        var applied = try plugin.apply(loadedPlan, request: loadedRequest, digest: loadedHash, to: project)
        XCTAssertEqual(applied.title, "新标题")
        XCTAssertEqual(applied.shots.first?.durationSeconds, 2.5)
        XCTAssertEqual(applied.candidateSnapshot, project.candidateSnapshot, "插件观察不能修改图库事实")
        var protectedRequest = request
        protectedRequest.shots[0].captionProtected = true
        XCTAssertThrowsError(try plugin.apply(plan, request: protectedRequest, digest: loadedHash, to: project))
        var captionPlan = plan
        captionPlan.shots[0].caption = request.shots[0].caption
        XCTAssertNoThrow(try plugin.apply(captionPlan, request: protectedRequest, digest: loadedHash, to: project))
        protectedRequest.shots[0].captionProtected = false
        protectedRequest.shots[0].durationProtected = true
        XCTAssertThrowsError(try plugin.apply(plan, request: protectedRequest, digest: loadedHash, to: project))
        var durationPlan = plan
        durationPlan.shots[0].durationFrames = request.shots[0].durationFrames
        XCTAssertNoThrow(try plugin.apply(durationPlan, request: protectedRequest, digest: loadedHash, to: project))
        let store = TimeStoryProjectStore(applicationSupportDirectory: root)
        applied.shots[0].caption = "用户修改"
        try store.save(applied)
        XCTAssertEqual(try store.load(applied.id), applied)
        var edited = project
        edited.shots[0].caption = "发布后用户编辑"
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: edited))
        plan.profile = "arbitrary-atelier"
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: project))
        try plugin.cancel(receipt)
        XCTAssertTrue(try plugin.status(receipt).contains("已取消"))
        XCTAssertThrowsError(try plugin.loadPlan(receipt))
        let retry = try await plugin.publish(project: project, aspect: .portrait, authorization: .init(endpoint: "https://example.invalid/v1/chat/completions", model: "synthetic"))
        XCTAssertNotEqual(retry.requestID, receipt.requestID)
    }

    func testCreativeManualOrderAllowsUnknownDatesAndPreservesLocks() throws {
        let root = try temporaryDirectory("creative-manual").resolvingSymlinksInPath()
        var project = renderProject(first: UUID(), second: UUID())
        project.shots.reverse()
        project.chapters[0].shotIDs = project.shots.map(\.id)
        project.shots[0].isLocked = true
        let base = try StoryCreativePlugin.fingerprint(project)
        let hash = String(repeating: "a", count: 64)
        let rid = "creative-" + UUID().uuidString.lowercased()
        project.creativeReceipt = .init(requestID: rid, requestSHA256: hash, baseFingerprint: base, aspect: .portrait)
        let request = StoryCreativeRequest(protocolVersion: "1.1", requestID: rid, projectID: "story-test", baseFingerprint: base,
            intent: "手动编排", subject: "合成", targetFrames: 300, aspect: .portrait, storySHA256: hash,
            facts: project.shots.map { .init(assetID: $0.assetID.uuidString, contentVersion: "v1", sha256: hash, captureTimeMs: nil, captureTimeSource: nil, placeName: nil) },
            shots: project.shots.map { .init(shotID: $0.id.uuidString.lowercased(), assetID: $0.assetID.uuidString, chapterID: $0.chapterID.uuidString.lowercased(), caption: $0.caption, durationFrames: Int(($0.durationSeconds * 30).rounded()), locked: $0.isLocked, userEdited: true) },
            chapters: project.chapters.map { .init(chapterID: $0.id.uuidString.lowercased(), title: $0.title) }, title: project.title)
        var plan = StoryCreativePlan(protocolVersion: "1.1", profile: "editable-story-v1", requestID: rid, requestSHA256: hash, pluginVersion: "1.1", planningMode: "agent-assisted", title: project.title, chapters: request.chapters,
            shots: request.shots.map { .init(shotID: $0.shotID, assetID: $0.assetID, chapterID: $0.chapterID, caption: $0.caption, durationFrames: $0.durationFrames, factRefs: [], rationale: "保留手动顺序") }, observations: [], uncertainties: [])
        let media = FixtureStoryMediaLoader(images: [:])
        let plugin = StoryCreativePlugin(rootProvider: FixtureOpenMontageRootProvider(root: root), exporter: StoryRenderPackageExporter(media: media, validator: PassingStoryValidator()), validator: PassingStoryValidator())
        let applied = try plugin.apply(plan, request: request, digest: hash, to: project)
        XCTAssertEqual(applied.shots.map(\.id), project.shots.map(\.id))
        XCTAssertEqual(applied.shots.map(\.durationSeconds), project.shots.map(\.durationSeconds))
        plan.shots.reverse()
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: project))
        plan.shots.reverse()
        plan.shots[0].durationFrames += 1
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: project))
    }

    func testCreativeProtectionSeparatesLegacySelectionFromExplicitEdits() throws {
        var shot = renderProject(first: UUID(), second: UUID()).shots[0]
        shot.reasons = ["手动编排"]
        shot.isLocked = true
        shot.isUserEdited = true
        shot.caption = ""
        shot.durationSeconds = TimeStoryConstants.defaultShotDurationSeconds
        XCTAssertFalse(shot.hasExplicitLock)
        XCTAssertFalse(shot.protectsCaption)
        XCTAssertFalse(shot.protectsDuration)
        shot.captionEdited = true
        XCTAssertTrue(shot.protectsCaption)
        XCTAssertFalse(shot.protectsDuration)
        shot.durationEdited = true
        XCTAssertTrue(shot.protectsDuration)
        shot.explicitLock = true
        XCTAssertTrue(shot.hasExplicitLock)
        let restored = try JSONDecoder().decode(TimeStoryShot.self, from: JSONEncoder().encode(shot))
        XCTAssertEqual(restored, shot)
        shot.explicitLock = false
        XCTAssertFalse(shot.hasExplicitLock)
    }

    func testCreativePluginRejectsLockedChangesAndUnsafePath() throws {
        let root = try temporaryDirectory("creative-lock").resolvingSymlinksInPath()
        let first = UUID(), second = UUID()
        var project = renderProject(first: first, second: second)
        project.shots[0].isLocked = true
        let base = try StoryCreativePlugin.fingerprint(project)
        let rid = "creative-" + UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        project.creativeReceipt = .init(requestID: rid, requestSHA256: hash, baseFingerprint: base, aspect: .landscape)
        let request = StoryCreativeRequest(requestID: rid, projectID: "story-one", baseFingerprint: base, intent: "test", subject: "test", targetFrames: 180, aspect: .landscape, storySHA256: hash,
            facts: project.shots.enumerated().map { .init(assetID: $0.element.assetID.uuidString, contentVersion: "v1", sha256: hash, captureTimeMs: Int64($0.offset), captureTimeSource: nil, placeName: nil) },
            shots: project.shots.map { .init(shotID: $0.id.uuidString.lowercased(), assetID: $0.assetID.uuidString, chapterID: $0.chapterID.uuidString.lowercased(), caption: $0.caption, durationFrames: 45, locked: $0.isLocked, userEdited: false) },
            chapters: project.chapters.map { .init(chapterID: $0.id.uuidString.lowercased(), title: $0.title) }, title: project.title)
        let plan = StoryCreativePlan(protocolVersion: "1.0", profile: "editable-story-v1", requestID: rid, requestSHA256: hash, pluginVersion: "1", planningMode: "agent-assisted", title: project.title, chapters: request.chapters,
            shots: request.shots.map { .init(shotID: $0.shotID, assetID: $0.assetID, chapterID: $0.chapterID, caption: "changed", durationFrames: 45, factRefs: [], rationale: "test") }, observations: [], uncertainties: [])
        let media = FixtureStoryMediaLoader(images: [:])
        let plugin = StoryCreativePlugin(rootProvider: FixtureOpenMontageRootProvider(root: root), exporter: StoryRenderPackageExporter(media: media, validator: PassingStoryValidator()), validator: PassingStoryValidator())
        XCTAssertThrowsError(try plugin.apply(plan, request: request, digest: hash, to: project))
        XCTAssertThrowsError(try StoryCreativePlugin.safe("../escape", root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
        XCTAssertThrowsError(try StoryCreativePlugin.safe("link/anything", root: root))
    }

    func testAtelierPublishesOnlySelectedPhotosAndRejectsVersionMismatch() async throws {
        let root = try temporaryDirectory("atelier-scope").resolvingSymlinksInPath()
        let first = UUID(), second = UUID(), third = UUID()
        var project = renderProject(first: first, second: second)
        project.creativeIntent = "用已选合成照片比较人物与环境关系"
        project.creativeTargetFrames = 600
        project.shots[0].isLocked = true
        project.candidateSnapshot = makeSnapshot(project.candidateSnapshot.candidates + [candidate(third.uuidString, time: timestamp(2024, 1, 2))])
        project.candidateSnapshot = makeSnapshot(project.candidateSnapshot.candidates + (0..<30).map { _ in candidate(UUID().uuidString, time: timestamp(2024, 1, 2)) })
        project.excludedAssetIDs = [third]
        let media = FixtureStoryMediaLoader(images: [
            first: try pngData(color: .red, portrait: false),
            second: try pngData(color: .blue, portrait: true),
            third: try pngData(color: .green, portrait: true),
        ])
        let exchange = StoryAtelierExchange(rootProvider: FixtureOpenMontageRootProvider(root: root),
                                            media: media, validator: PassingStoryValidator())
        let creative = root.appendingPathComponent("creative")
        try FileManager.default.createDirectory(at: creative, withIntermediateDirectories: true)
        var capability: [String: Any] = ["protocolVersion": "2.0", "profile": "atelier-project-v1",
            "pluginID": "openmontage", "pluginVersion": "2.0.0", "planningMode": "agent-assisted",
            "automaticPlanning": false, "renderRuntime": "remotion", "compositionMode": "atelier"]
        let capabilityURL = creative.appendingPathComponent("atelier-capabilities.json")
        try JSONSerialization.data(withJSONObject: capability).write(to: capabilityURL)
        let receipt = try await exchange.publish(project: project)
        let directory = creative.appendingPathComponent("atelier-requests/" + receipt.requestID)
        let requestData = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        let request = try JSONDecoder().decode(StoryAtelierRequest.self, from: requestData)
        let requestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        XCTAssertTrue(requestObject["feedback"] is NSNull)
        XCTAssertTrue(requestObject["parentProjectRevision"] is NSNull)
        let encodedAssets = try XCTUnwrap(requestObject["assets"] as? [[String: Any]])
        XCTAssertTrue(encodedAssets.allSatisfy { $0.keys.contains("placeName") })
        XCTAssertEqual(StoryCreativePlugin.hash(requestData), receipt.requestSHA256)
        XCTAssertEqual(request.assets.count, 2, "制作范围必须与用户已选照片一致")
        XCTAssertEqual(request.selectedAssetIDs.count, 2)
        XCTAssertEqual(request.lockedAssetIDs.count, 1)
        XCTAssertEqual(request.excludedAssetIDs.count, 0)
        XCTAssertEqual(request.scopeDigestSHA256, StoryAtelierExchange.scopeDigest(request.assets))
        XCTAssertFalse(request.externalSendAllowed)
        let store = TimeStoryProjectStore(applicationSupportDirectory: root)
        project.atelierVersions = [receipt]
        try store.save(project)
        XCTAssertEqual(try store.load(project.id).atelierVersions, [receipt])
        let parentRevision = String(repeating: "b", count: 64)
        let revised = try await exchange.publish(
            project: project, feedback: "让双图关系多停留两秒",
            parentProjectRevision: parentRevision)
        let revisedData = try Data(contentsOf: creative.appendingPathComponent(
            "atelier-requests/\(revised.requestID)/request.json"))
        let revisedRequest = try JSONDecoder().decode(StoryAtelierRequest.self, from: revisedData)
        XCTAssertEqual(revised.requestRevision, 2)
        XCTAssertEqual(revisedRequest.feedback, "让双图关系多停留两秒")
        XCTAssertEqual(revisedRequest.parentProjectRevision, parentRevision)
        XCTAssertEqual(revisedRequest.scopeDigestSHA256, request.scopeDigestSHA256)
        XCTAssertEqual(revisedRequest.lockedAssetIDs, request.lockedAssetIDs)
        XCTAssertEqual(revisedRequest.excludedAssetIDs, request.excludedAssetIDs)
        let asset = try XCTUnwrap(request.assets.first)
        try Data("tampered".utf8).write(to: directory.appendingPathComponent(asset.relativePath))
        XCTAssertThrowsError(try exchange.loadProposal(receipt, project: project))
        capability["protocolVersion"] = "3.0"
        try JSONSerialization.data(withJSONObject: capability).write(to: capabilityURL)
        do {
            _ = try await exchange.publish(project: project)
            XCTFail("Unsupported protocol version must fail")
        } catch { }
    }

    func testAtelierPublishes35SelectedWithUnknownDate() async throws {
        let root = try temporaryDirectory("atelier-35").resolvingSymlinksInPath()
        var project = renderProject(first: UUID(), second: UUID())
        let candidates = (0..<35).map { index in candidate(UUID().uuidString, time: index == 0 ? nil : Int64(1000 - index)) }
        project.candidateSnapshot = makeSnapshot(candidates)
        project.shots = candidates.enumerated().map { index, item in
            var shot = makeShot(asset: item, index: index)
            shot.chapterID = project.chapters[0].id
            shot.isLocked = true
            shot.durationSeconds = 1.5
            return shot
        }
        project.chapters[0].shotIDs = project.shots.map(\.id)
        project.creativeIntent = "保留合成镜头顺序"
        let image = try pngData(color: .blue, portrait: true)
        let media = FixtureStoryMediaLoader(images: Dictionary(uniqueKeysWithValues: candidates.map { ($0.assetID, image) }))
        let exchange = StoryAtelierExchange(rootProvider: FixtureOpenMontageRootProvider(root: root), media: media, validator: PassingStoryValidator())
        let creative = root.appendingPathComponent("creative")
        try FileManager.default.createDirectory(at: creative, withIntermediateDirectories: true)
        let capability: [String: Any] = ["protocolVersion": "2.1", "profile": "atelier-project-v1", "pluginID": "openmontage", "pluginVersion": "2.1.0", "planningMode": "agent-assisted", "automaticPlanning": false, "renderRuntime": "remotion", "compositionMode": "atelier"]
        try JSONSerialization.data(withJSONObject: capability).write(to: creative.appendingPathComponent("atelier-capabilities.json"))
        let receipt = try await exchange.publish(project: project)
        let request = try JSONDecoder().decode(StoryAtelierRequest.self, from: Data(contentsOf: creative.appendingPathComponent("atelier-requests/\(receipt.requestID)/request.json")))
        XCTAssertEqual(request.protocolVersion, "2.1")
        XCTAssertEqual(request.assets.count, 35)
        XCTAssertEqual(request.selectedAssetIDs, project.shots.map { StoryRenderPackageExporter.packageAssetID(projectID: project.id, assetID: $0.assetID) })
        XCTAssertEqual(request.lockedShots.map(\.durationFrames), Array(repeating: 45, count: 35))
        XCTAssertEqual(request.lockedShots.map(\.orderIndex), Array(0..<35))
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

    private func makeOpenMontageClient(
        root: URL,
        projectAssetImages: [UUID: Data],
        now: Date
    ) -> FileOpenMontageStoryTaskClient {
        FileOpenMontageStoryTaskClient(
            rootProvider: FixtureOpenMontageRootProvider(root: root),
            packageExporter: StoryRenderPackageExporter(
                media: FixtureStoryMediaLoader(images: projectAssetImages),
                validator: PassingStoryValidator()
            ),
            installationID: "imageall-test-installation",
            applicationVersion: "tests",
            now: { now }
        )
    }

    private func writeOpenMontageExecutorFixture(at root: URL, now: Date) throws {
        let executor = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: executor, withIntermediateDirectories: true)
        try writeJSON([
            "documentType": "story-executor-capabilities",
            "protocolVersion": FileOpenMontageStoryTaskClient.protocolVersion,
            "executorName": "openmontage-story-executor",
            "executorVersion": "tests",
            "instanceID": "fixture-instance",
            "taskProtocolSchemaSHA256": FileOpenMontageStoryTaskClient.protocolSchemaSHA256,
            "storyPackageSchemas": [[
                "version": StoryRenderPackageExporter.schemaVersion,
                "sha256": StoryRenderPackageExporter.schemaSHA256,
            ]],
            "taskTypes": ["story-render"],
            "maxConcurrentTasks": 1,
            "features": [
                "cancellation": true,
                "restartRecovery": true,
                "atomicResultPublication": true,
                "remoteAPI": false,
            ],
            "readiness": ["ready": true, "checks": []],
            "generatedAt": iso8601(now),
        ], to: executor.appendingPathComponent("capabilities.json"))
        try writeJSON([
            "documentType": "story-executor-heartbeat",
            "protocolVersion": FileOpenMontageStoryTaskClient.protocolVersion,
            "executorVersion": "tests",
            "instanceID": "fixture-instance",
            "pid": 1,
            "sequence": 1,
            "availability": "ready",
            "activeTaskID": NSNull(),
            "startedAt": iso8601(now),
            "updatedAt": iso8601(now),
        ], to: executor.appendingPathComponent("heartbeat.json"))
    }

    private func writeOpenMontageStatus(
        at taskRoot: URL,
        snapshot: OpenMontageStoryTaskSnapshot,
        digest: String,
        sequence: Int,
        state: String,
        stage: String,
        progress: Double,
        terminal: Bool,
        error: [String: Any]? = nil,
        now: Date
    ) throws {
        let stateRoot = taskRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try writeJSON([
            "documentType": "story-task-status",
            "protocolVersion": FileOpenMontageStoryTaskClient.protocolVersion,
            "taskID": snapshot.taskID,
            "projectID": snapshot.projectID,
            "projectRevision": try XCTUnwrap(snapshot.projectRevision),
            "submissionDigestSHA256": digest,
            "eventSequence": sequence,
            "state": state,
            "stage": stage,
            "progress": progress,
            "terminal": terminal,
            "updatedAt": iso8601(now),
            "error": error.map { $0 as Any } ?? NSNull(),
        ], to: stateRoot.appendingPathComponent("status.json"))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

private struct FixtureOpenMontageRootProvider: OpenMontageTaskRootProviding {
    let root: URL

    func resolveTaskRoot() throws -> URL { root }
    func startAccessing(_: URL) -> Bool { true }
    func stopAccessing(_: URL) {}
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

private actor CountingStoryThumbnailLoader: TimeStoryMediaLoading {
    let data: Data
    private var thumbnails = 0
    private var previews = 0
    init(data: Data) { self.data = data }
    func loadStoryThumbnail(assetID: UUID) async throws -> Data {
        thumbnails += 1
        try await Task.sleep(for: .milliseconds(30))
        return data
    }
    func loadStoryImage(assetID: UUID) async throws -> Data { previews += 1; return data }
    func counts() -> (Int, Int) { (thumbnails, previews) }
}
private struct DeniedStoryRootProvider: OpenMontageTaskRootProviding {
    func resolveTaskRoot() throws -> URL { throw OpenMontageTaskError.taskRootAuthorizationRequired }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

private final class StoryTaskRootBookmarkFixture: SecurityScopedBookmarkPort, @unchecked Sendable {
    let url: URL
    var active = 0
    var reject = false
    init(url: URL) { self.url = url }
    func createReadOnlyBookmark(for url: URL) throws -> Data { try createWritableBookmark(for: url) }
    func createWritableBookmark(for url: URL) throws -> Data {
        guard active > 0 else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        return Data("fresh".utf8)
    }
    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        BookmarkResolveResult(url: url, isStale: bookmark == Data("old".utf8))
    }
    func startAccessing(_ url: URL) -> Bool { if reject { return false }; active += 1; return true }
    func stopAccessing(_ url: URL) { active -= 1 }
}

private struct FixtureMixedStoryMedia: TimeStoryMediaLoading {
    static func makeMovingVideo(at url: URL, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        input.transform = transform
        writer.add(input)
        guard writer.startWriting() else { throw TimeStoryError.renderingFailed("fixture writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
            guard let buffer else { throw TimeStoryError.renderingFailed("fixture buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 128, height: 128,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 10 + frame * 3, y: 50, width: 16, height: 24))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw TimeStoryError.renderingFailed("fixture append")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw TimeStoryError.renderingFailed("fixture finalize") }
    }

    let images: [UUID: Data]
    let video: URL
    func loadStoryImage(assetID: UUID) async throws -> Data {
        guard let image = images[assetID] else { throw TimeStoryError.noCandidates }
        return image
    }
    func freezeStoryVideo(assetID: UUID, expectedRevision: Int, destination: URL) async throws -> TimeStoryFrozenVideo {
        try FileManager.default.copyItem(at: video, to: destination)
        let bytes = try Data(contentsOf: destination)
        return TimeStoryFrozenVideo(url: destination, contentRevision: expectedRevision, durationMs: 1000,
            mediaType: "public.mpeg-4", byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
    }
}
