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
#endif
