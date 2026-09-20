#if DEBUG
import AppKit
import Foundation
import GRDB
import SwiftUI

/// A temporary catalog plus synthetic pixels. The production library workspace never starts.
@MainActor
struct TimeStoryVerificationContainer: View {
    @StateObject private var model: TimeStoryWorkspaceModel
    @State private var openedStory = false

    init() { _model = StateObject(wrappedValue: try! Self.makeModel()) }

    var body: some View {
        if openedStory {
            TimeStoryWorkspaceView(model: model)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("标签").font(.largeTitle.bold())
                HStack {
                    Label("合成主体", systemImage: "tag")
                    Spacer()
                    Menu("管理") {
                        TimeStoryCreationButton(tag: Self.subject) { _ in openedStory = true }
                    }.accessibilityIdentifier("timeStoryVerificationTagMenu")
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("隔离合成验收：511 张已确认候选跨越 200 条分页；无真实照片访问。")
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(minWidth: 720, minHeight: 460, alignment: .topLeading)
        }
    }

    static let subject = TagListItem(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        displayName: "合成主体", state: .active
    )
    private static let distractor = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private static let sourceID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

    private struct Fact {
        let number: Int
        let time: Int64?
        let place: String?
        let location: String?
        let availability: String
        let cluster: String?
        let decision: String?
        let favorite: Bool
        let portrait: Bool
        var id: String { String(format: "10000000-0000-0000-0000-%012d", number) }
    }

    private static func makeModel() throws -> TimeStoryWorkspaceModel {
        let requestedRun = ProcessInfo.processInfo.environment["IMAGEALL_TIME_STORY_VERIFICATION_RUN_ID"]
        let runID = requestedRun.flatMap { raw -> String? in
            guard !raw.isEmpty, raw.count <= 64,
                  raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            return raw
        } ?? UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-TimeStory-Phase4-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let images = try seedSyntheticCatalog(database)
        let media = TimeStoryVerificationMedia(images: images)
        let validator = TimeStoryMediaValidator(database: database)
        let packageExporter = StoryRenderPackageExporter(media: media, validator: validator)
        let taskRootStore = UserDefaultsOpenMontageTaskRootStore()
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(database: database, query: GRDBAssetCatalogQueryRepository(database: database)),
            planner: TimeStoryPlanner(),
            store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: validator,
            renderer: AVFoundationTimeStoryRenderer(
                media: media, temporaryDirectory: root.appendingPathComponent("render", isDirectory: true)
            ),
            packageExporter: packageExporter,
            openMontageTasks: FileOpenMontageStoryTaskClient(
                rootProvider: taskRootStore, packageExporter: packageExporter,
                installationID: taskRootStore.installationID
            ),
            media: media,
            clock: SystemJobClock()
        )
        let model = TimeStoryWorkspaceModel(runtime: runtime, tag: subject)
        model.message = "合成验收模式：使用临时数据库和合成像素。"
        return model
    }

    static func seedSyntheticCatalog(_ database: CatalogDatabase) throws -> [UUID: Data] {
        let facts = [
            Fact(number: 1, time: 1_514_764_800_000, place: nil, location: "none", availability: "available", cluster: "growth-pose", decision: "accepted", favorite: true, portrait: true),
            Fact(number: 2, time: 1_546_300_800_000, place: "A 城", location: "placeTag", availability: "available", cluster: "early-event", decision: "accepted", favorite: true, portrait: false),
            Fact(number: 3, time: 1_546_300_860_000, place: "A 城", location: "placeTag", availability: "available", cluster: "early-event", decision: "accepted", favorite: false, portrait: true),
            Fact(number: 4, time: 1_609_459_200_000, place: "B 城", location: "placeTag", availability: "available", cluster: nil, decision: "accepted", favorite: true, portrait: false),
            Fact(number: 5, time: 1_610_323_200_000, place: "B 城", location: "placeTag", availability: "available", cluster: nil, decision: "accepted", favorite: false, portrait: true),
            Fact(number: 6, time: 1_735_689_600_000, place: "A 城", location: "placeTag", availability: "available", cluster: "growth-pose", decision: "accepted", favorite: true, portrait: true),
            Fact(number: 7, time: 1_736_553_600_000, place: "A 城", location: "placeTag", availability: "available", cluster: nil, decision: "accepted", favorite: false, portrait: false),
            Fact(number: 8, time: nil, place: nil, location: nil, availability: "available", cluster: nil, decision: "accepted", favorite: false, portrait: true),
            Fact(number: 9, time: 1_720_000_000_000, place: "A 城", location: "placeTag", availability: "missing", cluster: nil, decision: "accepted", favorite: false, portrait: false),
            Fact(number: 10, time: 1_650_000_000_000, place: nil, location: "embeddedGPS", availability: "available", cluster: nil, decision: "accepted", favorite: false, portrait: false),
            Fact(number: 11, time: 1_550_000_000_000, place: "A 城", location: "placeTag", availability: "available", cluster: nil, decision: nil, favorite: false, portrait: true),
            Fact(number: 12, time: 1_550_000_000_000, place: "A 城", location: "placeTag", availability: "available", cluster: nil, decision: "rejected", favorite: false, portrait: true),
            Fact(number: 13, time: 1_550_000_000_000, place: "B 城", location: "placeTag", availability: "available", cluster: nil, decision: "distractor", favorite: false, portrait: false),
        ] + (100 ... 600).map { number in
            Fact(number: number, time: 1_737_417_600_000 + Int64(number - 100) * 3_600_000,
                 place: "A 城", location: "placeTag", availability: "available",
                 cluster: "recent-event-\((number - 100) / 2)", decision: "accepted",
                 favorite: false, portrait: number.isMultiple(of: 2))
        }
        let source = sourceID
        let tag = subject.id.uuidString.lowercased()
        let other = distractor
        let alreadySeeded = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?", arguments: [source]) ?? 0
        } > 0
        if !alreadySeeded {
            try database.pool.write { db in
            try db.execute(sql: "INSERT INTO source (id,kind,display_name,bookmark,state,created_at_ms,updated_at_ms) VALUES (?,'folder','合成来源',?,'active',1,1)", arguments: [source, Data("synthetic-only".utf8)])
            for (id, name) in [(tag, "合成主体"), (other, "干扰主体")] {
                try db.execute(sql: "INSERT INTO tag (id,name,normalized_name,state,created_at_ms,updated_at_ms) VALUES (?,?,?,'active',1,1)", arguments: [id, name, name])
            }
            for (id, name, latitude, longitude) in [("a", "A 城", 31.0, 121.0), ("b", "B 城", 30.0, 120.0)] {
                try db.execute(sql: "INSERT INTO place (id,canonical_name,latitude,longitude,kind,created_at_ms,updated_at_ms) VALUES (?,?,?,?,'city',1,1)", arguments: [id, name, latitude, longitude])
            }
            try db.execute(sql: """
                INSERT INTO source_similarity_index
                    (source_id,media_kind,state,policy_version,feature_print_provider,
                     feature_print_request_revision,feature_print_preprocessing_revision,
                     feature_print_max_l2,lsh_bit_count,lsh_planes_json,asset_count,indexed_count,
                     cluster_count,pending_count,built_at_ms,updated_at_ms)
                VALUES (?,'image','ready','synthetic-v1','synthetic',1,1,1.0,8,?,514,505,252,9,1,1)
                """, arguments: [source, Data("[]".utf8)])
            for fact in facts {
                try db.execute(sql: """
                    INSERT INTO asset (id,source_id,locator_kind,relative_path,locator_state,file_name,
                        media_type,media_kind,width,height,media_created_at_ms,content_revision,
                        availability,record_created_at_ms,record_updated_at_ms)
                    VALUES (?,?,'file',?,'current',?,'public.png','image',?,?,?,1,?,1,1)
                    """, arguments: [fact.id, source, "synthetic/\(fact.id).png", "合成-\(fact.number).png",
                                     fact.portrait ? 700 : 1200, fact.portrait ? 1000 : 700,
                                     fact.time, fact.availability])
                if let decision = fact.decision {
                    try db.execute(sql: "INSERT INTO asset_tag_decision(asset_id,tag_id,decision,updated_at_ms) VALUES (?,?,?,1)",
                                   arguments: [fact.id, decision == "distractor" ? other : tag,
                                               decision == "distractor" ? "accepted" : decision])
                }
                if fact.favorite {
                    try db.execute(sql: "INSERT INTO asset_favorite_state(asset_id,desired_value,sync_status,requested_at_ms,updated_at_ms) VALUES (?,1,'localOnly',1,1)", arguments: [fact.id])
                }
                if let kind = fact.location {
                    let placeID: String? = fact.place == "A 城" ? "a" : fact.place == "B 城" ? "b" : nil
                    let latitude: Double? = kind == "none" ? nil : placeID == "b" ? 30.0 : 31.0
                    let longitude: Double? = kind == "none" ? nil : placeID == "b" ? 120.0 : 121.0
                    try db.execute(sql: "INSERT INTO asset_location(asset_id,latitude,longitude,source_kind,updated_at_ms,place_id) VALUES (?,?,?,?,1,?)",
                                   arguments: [fact.id, latitude, longitude, kind, placeID])
                }
                if let cluster = fact.cluster {
                    try db.execute(sql: "INSERT INTO source_similarity_bucket_member(source_id,media_kind,asset_id,content_revision,bucket_key,cluster_id) VALUES (?,'image',?,1,1,?)",
                                   arguments: [source, fact.id, cluster])
                }
            }
            let feedID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
            try db.execute(sql: """
                INSERT INTO contextual_tag_feed(id,tag_id,anchor_asset_id,source_id,group_key,
                    policy_revision,state,revision,created_at_ms,updated_at_ms)
                VALUES (?,?,?,?,?,'synthetic-v1','pending',1,1,1)
                """, arguments: [feedID, tag, facts[0].id, source, String(repeating: "a", count: 64)])
            try db.execute(sql: "INSERT INTO contextual_tag_feed_member(feed_id,asset_id,role,rank,evidence_mask) VALUES (?,?,'candidate',0,1)",
                           arguments: [feedID, facts[10].id])
            }
        }
        let colors: [NSColor] = [.systemOrange, .systemRed, .systemBlue, .systemPurple, .systemGreen]
        let pixels = try colors.flatMap { color in
            try [syntheticPNG(color: color, portrait: false), syntheticPNG(color: color, portrait: true)]
        }
        return Dictionary(uniqueKeysWithValues: facts.filter { $0.availability == "available" }.map { fact in
            (UUID(uuidString: fact.id)!, pixels[(fact.number % colors.count) * 2 + (fact.portrait ? 1 : 0)])
        })
    }

    private static func syntheticPNG(color: NSColor, portrait: Bool) throws -> Data {
        let size = portrait ? NSSize(width: 700, height: 1_000) : NSSize(width: 1_200, height: 700)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.38, y: size.height * 0.35, width: 130, height: 130)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:])
        else { throw TimeStoryError.renderingFailed("无法创建合成验收图片") }
        return data
    }
}

private struct TimeStoryVerificationMedia: TimeStoryMediaLoading {
    let images: [UUID: Data]
    func loadStoryImage(assetID: UUID) async throws -> Data {
        guard let image = images[assetID] else { throw TimeStoryError.noCandidates }
        return image
    }
}

/// Opens a prefiltered private catalog without starting the production library workspace.
/// The catalog contains one user-authorized tag and existing folder bookmarks only.
@MainActor
struct TimeStoryTrialContainer: View {
    @State private var openedStory = false
    @State private var message: String?
    @State private var setup: Setup?
    @State private var setupError: String?
    private let requestedRootPath: String

    private final class RootAccessLease {
        let url: URL
        init(url: URL) { self.url = url }
        deinit { url.stopAccessingSecurityScopedResource() }
    }

    private struct Scope: Decodable {
        let tagID: UUID
        let tagDisplayName: String
        let candidateCount: Int
    }

    private struct Setup {
        let tag: TagListItem
        let candidateCount: Int
        let model: TimeStoryWorkspaceModel
        let taskRootStore: UserDefaultsOpenMontageTaskRootStore
        let rootAccessLease: RootAccessLease
    }

    private enum SetupError: LocalizedError {
        case invalidRoot
        case unexpectedCatalog
        case preferencesUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidRoot: "隔离试用目录无效。"
            case .unexpectedCatalog: "隔离目录库与授权标签范围不一致。"
            case .preferencesUnavailable: "无法创建隔离的制作目录设置。"
            }
        }
    }

    init(rootPath: String) {
        requestedRootPath = rootPath
        _setup = State(initialValue: nil)
        _setupError = State(initialValue: "请选择本轮隔离目录，授权安装版读取其中的限定目录库。")
    }

    var body: some View {
        if let setup {
            if openedStory {
                TimeStoryWorkspaceView(model: setup.model)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("隔离故事试用").font(.largeTitle.bold())
                    HStack {
                        Label(setup.tag.displayName, systemImage: "tag")
                        Spacer()
                        TimeStoryCreationButton(tag: setup.tag) { _ in openedStory = true }
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Text("本轮仅从隔离目录库中读取 \(setup.candidateCount) 张已确认候选；来源照片只读，故事项目与缓存留在隔离目录。")
                        .foregroundStyle(.secondary)
                    Button("选择本轮 OpenMontage 任务目录…") {
                        selectTaskRoot(setup.taskRootStore, model: setup.model)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(32)
                .frame(minWidth: 720, minHeight: 460, alignment: .topLeading)
            }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "隔离故事试用尚未连接",
                    systemImage: "folder.badge.questionmark",
                    description: Text(setupError ?? "请选择隔离项目目录。")
                )
                Button("选择隔离试用目录…") { selectTrialRoot() }
            }
            .frame(minWidth: 720, minHeight: 460)
        }
    }

    private func selectTrialRoot() {
        guard NSString(string: requestedRootPath).isAbsolutePath else {
            setupError = SetupError.invalidRoot.localizedDescription
            return
        }
        let expected = URL(fileURLWithPath: requestedRootPath, isDirectory: true).standardizedFileURL
        let panel = NSOpenPanel()
        panel.title = "选择本轮隔离试用目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = expected.deletingLastPathComponent()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        guard chosen.standardizedFileURL == expected else {
            setupError = "选择的目录与本轮隔离项目不一致。"
            return
        }
        guard chosen.startAccessingSecurityScopedResource() else {
            setupError = "无法取得隔离目录访问授权。"
            return
        }
        let lease = RootAccessLease(url: chosen)
        do {
            setup = try Self.makeSetup(root: chosen, lease: lease)
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func selectTaskRoot(
        _ store: UserDefaultsOpenMontageTaskRootStore,
        model: TimeStoryWorkspaceModel
    ) {
        let panel = NSOpenPanel()
        panel.title = "选择本轮隔离的 OpenMontage 任务目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.saveTaskRoot(url)
            message = "本轮制作目录已授权。"
            Task { await model.refreshOpenMontageCapability() }
        } catch {
            message = error.localizedDescription
        }
    }

    private static func makeSetup(root: URL, lease: RootAccessLease) throws -> Setup {
        guard root.path != "/", !root.path.hasPrefix("/Volumes/HDD2/") else {
            throw SetupError.invalidRoot
        }
        let scope = try JSONDecoder().decode(
            Scope.self,
            from: Data(contentsOf: root.appendingPathComponent("trial-scope.json"))
        )
        let database = try CatalogDatabase.openWithoutMigration(
            at: root.appendingPathComponent("catalog.sqlite")
        )
        try database.validateQuickCheck()
        let (assetCount, photosCount, tagCount) = try database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE kind='photos'") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE id=? AND state='active'", arguments: [scope.tagID.uuidString.lowercased()]) ?? 0
            )
        }
        guard assetCount == scope.candidateCount, photosCount == 0, tagCount == 1 else {
            throw SetupError.unexpectedCatalog
        }
        guard let trialDefaults = UserDefaults(suiteName: "com.gwlee.ImageAll.TimeStoryTrial") else {
            throw SetupError.preferencesUnavailable
        }
        let clock = SystemJobClock()
        let bookmark = FoundationSecurityScopedBookmarkAdapter()
        let sourceAccess = FolderReconcileSourceAccessService(
            repository: GRDBFolderSourceAuthorizationRepository(database: database),
            bookmarkPort: bookmark,
            rootValidator: FolderRootValidator(),
            clock: clock
        )
        let derivedImages = DerivedImageCacheService(
            database: database,
            cachesDirectory: root
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("ImageAll", isDirectory: true),
            sourceAccess: sourceAccess,
            clock: clock
        )
        let media = LibraryAssetImageLoader(
            database: database,
            fileImages: derivedImages,
            photosImages: PhotoKitPhotosLibraryAdapter()
        )
        let validator = TimeStoryMediaValidator(database: database)
        let packageExporter = StoryRenderPackageExporter(media: media, validator: validator)
        let taskRootStore = UserDefaultsOpenMontageTaskRootStore(defaults: trialDefaults)
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(
                database: database,
                query: GRDBAssetCatalogQueryRepository(database: database)
            ),
            planner: TimeStoryPlanner(),
            store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: validator,
            renderer: AVFoundationTimeStoryRenderer(
                media: media,
                temporaryDirectory: root.appendingPathComponent("Rendering", isDirectory: true)
            ),
            packageExporter: packageExporter,
            openMontageTasks: FileOpenMontageStoryTaskClient(
                rootProvider: taskRootStore,
                packageExporter: packageExporter,
                installationID: taskRootStore.installationID
            ),
            media: media,
            clock: clock
        )
        return Setup(
            tag: TagListItem(id: scope.tagID, displayName: scope.tagDisplayName, state: .active),
            candidateCount: scope.candidateCount,
            model: TimeStoryWorkspaceModel(
                runtime: runtime,
                tag: TagListItem(id: scope.tagID, displayName: scope.tagDisplayName, state: .active)
            ),
            taskRootStore: taskRootStore,
            rootAccessLease: lease
        )
    }
}
#endif
