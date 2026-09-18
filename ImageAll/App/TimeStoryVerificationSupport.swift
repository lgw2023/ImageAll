#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor
struct TimeStoryVerificationContainer: View {
    @StateObject private var model: TimeStoryWorkspaceModel
    @State private var openedStory = false

    init() {
        _model = StateObject(wrappedValue: try! Self.makeModel())
    }

    var body: some View {
        if openedStory {
            TimeStoryWorkspaceView(model: model)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("标签")
                    .font(.largeTitle.bold())
                HStack {
                    Label("合成主体", systemImage: "tag")
                    Spacer()
                    Menu("管理") {
                        TimeStoryCreationButton(tag: TagListItem(
                            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                            displayName: "合成主体",
                            state: .active
                        )) { _ in
                            openedStory = true
                        }
                    }
                    .accessibilityIdentifier("timeStoryVerificationTagMenu")
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("合成验收模式：从标签入口进入；未读取真实照片。")
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(minWidth: 720, minHeight: 460, alignment: .topLeading)
        }
    }

    private static func makeModel() throws -> TimeStoryWorkspaceModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-TimeStory-UI-Verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        let tag = TagListItem(id: UUID(), displayName: "合成主体", state: .active)
        let specs: [(String, Int64, String?, NSColor, Bool)] = [
            ("10000000-0000-0000-0000-000000000001", 1_514_764_800_000, nil, .systemOrange, true),
            ("10000000-0000-0000-0000-000000000002", 1_609_459_200_000, "上海", .systemRed, false),
            ("10000000-0000-0000-0000-000000000003", 1_672_531_200_000, "杭州", .systemBlue, true),
            ("10000000-0000-0000-0000-000000000004", 1_735_689_600_000, "上海", .systemPurple, false),
        ]
        let sourceID = UUID()
        let candidates = specs.map { rawID, time, place, _, _ in
            TimeStoryCandidate(
                assetID: UUID(uuidString: rawID)!,
                contentRevision: 1,
                sourceID: sourceID,
                fileName: "\(rawID).png",
                mediaCreatedAtMs: time,
                width: 1_600,
                height: 1_000,
                availability: .available,
                isFavorite: rawID.hasSuffix("1"),
                locationState: place == nil ? .absent : .named,
                placeName: place,
                locationSource: place == nil ? "none" : "placeTag",
                similarityClusterID: rawID.hasSuffix("1") || rawID.hasSuffix("4") ? "growth-pose" : nil,
                similarityState: .ready
            )
        } + [
            TimeStoryCandidate(
                assetID: UUID(),
                contentRevision: 1,
                sourceID: sourceID,
                fileName: "unknown-time.png",
                mediaCreatedAtMs: nil,
                width: 1_600,
                height: 1_000,
                availability: .available,
                isFavorite: false,
                locationState: .unconfirmed,
                placeName: nil,
                locationSource: nil,
                similarityClusterID: nil,
                similarityState: .unavailable
            ),
        ]
        let snapshot = TimeStoryCandidateSnapshot(
            id: "verification-snapshot",
            createdAtMs: 1_757_808_000_000,
            tagID: tag.id,
            tagDisplayName: tag.displayName,
            candidates: candidates
        )
        let project = try TimeStoryPlanner().makeProject(snapshot: snapshot, nowMs: 1_757_808_000_000)
        var mediaData: [UUID: Data] = [:]
        var thumbnails: [UUID: NSImage] = [:]
        for (rawID, _, _, color, portrait) in specs {
            let id = UUID(uuidString: rawID)!
            let data = try syntheticPNG(color: color, portrait: portrait)
            mediaData[id] = data
            if let shot = project.shots.first(where: { $0.assetID == id }), let image = NSImage(data: data) {
                thumbnails[shot.id] = image
            }
        }
        let media = TimeStoryVerificationMedia(images: mediaData)
        let runtime = TimeStoryFeatureRuntime(
            candidates: TimeStoryCandidateProvider(database: database, query: TimeStoryVerificationQuery()),
            planner: TimeStoryPlanner(),
            store: TimeStoryProjectStore(applicationSupportDirectory: root),
            validator: TimeStoryVerificationValidator(),
            renderer: AVFoundationTimeStoryRenderer(
                media: media,
                temporaryDirectory: root.appendingPathComponent("render", isDirectory: true)
            ),
            media: media,
            clock: SystemJobClock()
        )
        return TimeStoryWorkspaceModel(
            verificationRuntime: runtime,
            tag: tag,
            project: project,
            thumbnails: thumbnails
        )
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

private struct TimeStoryVerificationValidator: TimeStoryMediaValidating {
    func validate(_ project: TimeStoryProject) throws -> [TimeStoryMediaValidationIssue] { [] }
}

private struct TimeStoryVerificationQuery: AssetCatalogQueryPort {
    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult { throw VerificationError.unused }
    func fetchSourceFolders(sourceID: UUID) throws -> [LibrarySourceFolder] { throw VerificationError.unused }
    func fetchSourceFolderPage(
        sourceID: UUID,
        parentRelativePath: String?,
        offset: Int,
        limit: Int
    ) throws -> LibrarySourceFolderPage { throw VerificationError.unused }
    func sourceFolderExists(_ scope: AssetFolderScope) throws -> Bool { throw VerificationError.unused }
    func searchSourceFolders(
        sourceID: UUID,
        text: String,
        limit: Int
    ) throws -> LibrarySourceFolderPage { throw VerificationError.unused }
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot { throw VerificationError.unused }
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail { throw VerificationError.unused }
    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int { throw VerificationError.unused }

    private enum VerificationError: Error { case unused }
}
#endif
