import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TimeStoryPackageAspect: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case landscape
    case portrait

    var id: String { rawValue }
    var width: Int { self == .landscape ? 1_920 : 1_080 }
    var height: Int { self == .landscape ? 1_080 : 1_920 }
    var displayName: String { self == .landscape ? "横屏 16:9" : "竖屏 9:16" }
}

struct TimeStoryPackageProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparingAssets
        case writingPlan
        case verifying
        case publishing
    }

    let phase: Phase
    let fraction: Double
}

struct TimeStoryPackageExportResult: Sendable, Equatable {
    let packageURL: URL
    let projectID: String
    let projectRevision: String
    let totalFrames: Int
    let assetCount: Int
}

protocol TimeStoryPackageExporting: Sendable {
    func export(
        project: TimeStoryProject,
        aspect: TimeStoryPackageAspect,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TimeStoryPackageProgress) -> Void
    ) async throws -> TimeStoryPackageExportResult
}

struct StoryRenderPackageExporter: TimeStoryPackageExporting, Sendable {
    static let schemaVersion = "0.1"
    static let schemaCommit = "30d412449354efce1ec002539e471b7c067e11c7"
    static let schemaSHA256 = "884a6fed3eb4d8cf3b37c450b8a9a4e2d21782220532a66d21dccdf8fe696841"
    static let exporterVersion = "imageall-story-render-package-v0.1"

    let media: any TimeStoryMediaLoading
    let validator: any TimeStoryMediaValidating

    func export(
        project: TimeStoryProject,
        aspect: TimeStoryPackageAspect,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TimeStoryPackageProgress) -> Void
    ) async throws -> TimeStoryPackageExportResult {
        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path), destinationURL != parent else {
            throw TimeStoryError.invalidDestination
        }
        let timeline = try TimeStoryTimeline.normalize(project: project)
        let renderedProjectTitle = timeline.segments.first(where: { $0.kind == .projectTitle })?.title ?? ""
        guard renderedProjectTitle.count <= 240 else {
            throw TimeStoryError.storyPackageExportFailed("项目标题超过故事包允许的 240 个字符")
        }
        guard project.chapters.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 240 }) else {
            throw TimeStoryError.storyPackageExportFailed("章节标题为空或超过故事包允许的 240 个字符")
        }
        guard project.shots.allSatisfy({ $0.caption.count <= 240 }) else {
            throw TimeStoryError.storyPackageExportFailed("镜头字幕超过故事包允许的 240 个字符")
        }
        let initialIssues = try validator.validate(project)
        guard initialIssues.isEmpty else {
            throw TimeStoryError.mediaValidationFailed(initialIssues)
        }

        let staging = parent.appendingPathComponent(
            ".imageall-story-package-\(UUID().uuidString).pending",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: staging) }
        }
        let assetsDirectory = staging.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: false)

        let referencedShots = project.shots.reduce(into: [TimeStoryShot]()) { result, shot in
            if !result.contains(where: { $0.assetID == shot.assetID }) { result.append(shot) }
        }
        let revisionsByAsset = Dictionary(grouping: project.shots, by: \.assetID)
        guard revisionsByAsset.values.allSatisfy({ Set($0.map(\.contentRevision)).count == 1 }) else {
            throw TimeStoryError.storyPackageExportFailed("同一素材在项目中出现了不同内容版本")
        }

        var packageAssets: [StoryRenderPackageDocument.Asset] = []
        var packageAssetIDBySource: [UUID: String] = [:]
        for (index, shot) in referencedShots.enumerated() {
            try Task.checkCancellation()
            let packageAssetID = Self.opaqueID(
                prefix: "photo",
                components: [project.id.uuidString, shot.assetID.uuidString]
            )
            let relativePath = "assets/\(packageAssetID).jpg"
            let destination = staging.appendingPathComponent(relativePath)
            let sourceData = try await media.loadStoryImage(assetID: shot.assetID)
            try Self.writeNormalizedJPEG(sourceData, to: destination)
            let hash = try Self.fileSHA256(destination)
            packageAssetIDBySource[shot.assetID] = packageAssetID
            packageAssets.append(.init(
                assetID: packageAssetID,
                relativePath: relativePath,
                mediaType: "image/jpeg",
                sourceContentVersion: "catalog-revision-\(shot.contentRevision)",
                renderFileSHA256: hash
            ))
            onProgress(.init(
                phase: .preparingAssets,
                fraction: Double(index + 1) / Double(max(1, referencedShots.count + (project.music == nil ? 0 : 1)))
            ))
        }

        var audio: StoryRenderPackageDocument.Audio?
        if let music = project.music {
            try Task.checkCancellation()
            let resolved = try Self.resolveMusicURL(music)
            let didAccess = resolved.startAccessingSecurityScopedResource()
            defer { if didAccess { resolved.stopAccessingSecurityScopedResource() } }
            let (extensionName, mediaType) = try Self.supportedAudioType(resolved)
            let beforeHash = try Self.fileSHA256(resolved)
            let assetID = Self.opaqueID(
                prefix: "audio",
                components: [project.id.uuidString, beforeHash]
            )
            let relativePath = "assets/\(assetID).\(extensionName)"
            let copied = staging.appendingPathComponent(relativePath)
            try fileManager.copyItem(at: resolved, to: copied)
            let copiedHash = try Self.fileSHA256(copied)
            let afterHash = try Self.fileSHA256(resolved)
            guard beforeHash == copiedHash, beforeHash == afterHash else {
                throw TimeStoryError.storyPackageExportFailed("配乐在导出期间发生变化")
            }
            packageAssets.append(.init(
                assetID: assetID,
                relativePath: relativePath,
                mediaType: mediaType,
                sourceContentVersion: "sha256:\(beforeHash)",
                renderFileSHA256: copiedHash
            ))
            audio = .init(
                assetID: assetID,
                offsetFrame: 0,
                volume: 0.22,
                fadeInFrames: min(60, timeline.totalFrames),
                fadeOutFrames: min(90, timeline.totalFrames),
                loop: true
            )
            onProgress(.init(phase: .preparingAssets, fraction: 1))
        }

        let finalIssues = try validator.validate(project)
        guard finalIssues.isEmpty else {
            throw TimeStoryError.mediaValidationFailed(finalIssues)
        }
        try Task.checkCancellation()

        let chapters = try Self.makeChapters(
            project: project,
            timeline: timeline,
            packageAssetIDBySource: packageAssetIDBySource
        )
        var document = StoryRenderPackageDocument(
            schemaVersion: Self.schemaVersion,
            projectID: Self.packageProjectID(for: project.id),
            projectRevision: "pending",
            export: .init(
                width: aspect.width,
                height: aspect.height,
                fps: timeline.fps,
                totalFrames: timeline.totalFrames,
                background: .init(
                    color: "#0E151F",
                    mode: "blurred-photo",
                    blurPixels: 28,
                    dimOpacity: 0.42
                ),
                template: .init(
                    name: "family-photo-story",
                    version: "0.1",
                    title: renderedProjectTitle,
                    subtitle: nil,
                    closingText: nil,
                    fontFamily: "PingFang SC",
                    textColor: "#FFFFFF",
                    accentColor: "#F2C879",
                    safeMarginRatio: 0.07
                )
            ),
            assets: packageAssets,
            chapters: chapters,
            audio: audio,
            trace: .init(
                upstreamPolicyVersion: project.strategyVersion,
                exporterVersion: Self.exporterVersion
            )
        )
        let revisionInput = try Self.encoder.encode(document)
        document.projectRevision = "sha256:\(Self.sha256(revisionInput))"
        let storyURL = staging.appendingPathComponent("story.json")
        try Self.encoder.encode(document).write(to: storyURL, options: [.atomic])
        onProgress(.init(phase: .writingPlan, fraction: 1))

        try Self.validate(document: document, packageRoot: staging)
        onProgress(.init(phase: .verifying, fraction: 1))
        try Task.checkCancellation()
        onProgress(.init(phase: .publishing, fraction: 0))
        try Self.publish(staging, to: destinationURL)
        published = true
        onProgress(.init(phase: .publishing, fraction: 1))
        return TimeStoryPackageExportResult(
            packageURL: destinationURL,
            projectID: document.projectID,
            projectRevision: document.projectRevision,
            totalFrames: timeline.totalFrames,
            assetCount: document.assets.count
        )
    }

    private static func makeChapters(
        project: TimeStoryProject,
        timeline: TimeStoryFrameTimeline,
        packageAssetIDBySource: [UUID: String]
    ) throws -> [StoryRenderPackageDocument.Chapter] {
        try project.chapters.enumerated().map { chapterIndex, chapter in
            let segments = timeline.segments.filter { $0.chapterID == chapter.id }
            guard !segments.isEmpty else {
                throw TimeStoryError.invalidTimeline("章节没有规范化镜头")
            }
            let shots = try segments.enumerated().map { sequenceIndex, segment in
                let kind: String = switch segment.kind {
                case .projectTitle: "title"
                case .chapterTitle: "chapter-title"
                case .photo: "photo"
                }
                let assetID: String?
                if let sourceAssetID = segment.assetID {
                    guard let mapped = packageAssetIDBySource[sourceAssetID] else {
                        throw TimeStoryError.storyPackageExportFailed("镜头素材没有导出")
                    }
                    assetID = mapped
                } else {
                    assetID = nil
                }
                return StoryRenderPackageDocument.Shot(
                    shotID: opaqueID(
                        prefix: "shot",
                        components: [project.id.uuidString, segment.id.uuidString]
                    ),
                    sequenceIndex: sequenceIndex,
                    kind: kind,
                    assetID: assetID,
                    startFrame: segment.startFrame,
                    durationFrames: segment.durationFrames,
                    title: segment.title,
                    caption: segment.caption.flatMap { value in
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : .init(body: value)
                    },
                    fit: segment.kind == .photo ? .init(mode: "contain", allowCrop: false) : nil,
                    motion: segment.kind == .photo
                        ? .init(type: "subtle-push", startScale: 0.985, endScale: 1.0)
                        : nil,
                    transitionIn: .init(
                        type: segment.transitionInFrames == 0 ? "cut" : "fade",
                        durationFrames: segment.transitionInFrames
                    ),
                    trace: .init(
                        originalShotID: opaqueID(
                            prefix: "source-shot",
                            components: [project.id.uuidString, (segment.shotID ?? segment.id).uuidString]
                        ),
                        upstreamStrategyVersion: project.strategyVersion
                    )
                )
            }
            return StoryRenderPackageDocument.Chapter(
                chapterID: opaqueID(
                    prefix: "chapter",
                    components: [project.id.uuidString, chapter.id.uuidString]
                ),
                sequenceIndex: chapterIndex,
                title: chapter.title,
                shots: shots,
                trace: .init(
                    sourceChapterID: opaqueID(
                        prefix: "source-chapter",
                        components: [project.id.uuidString, chapter.id.uuidString]
                    ),
                    upstreamStrategyVersion: project.strategyVersion
                )
            )
        }
    }

    static func writeNormalizedJPEG(_ sourceData: Data, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw TimeStoryError.storyPackageExportFailed("正式素材无法解码")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destinationWriter = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              )
        else {
            throw TimeStoryError.storyPackageExportFailed("正式素材方向归一化失败")
        }
        CGImageDestinationAddImage(destinationWriter, image, [
            kCGImageDestinationLossyCompressionQuality: 0.94,
            kCGImagePropertyOrientation: 1,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destinationWriter) else {
            throw TimeStoryError.storyPackageExportFailed("正式 JPEG 写入失败")
        }
    }

    private static func validate(
        document: StoryRenderPackageDocument,
        packageRoot: URL
    ) throws {
        guard document.schemaVersion == schemaVersion,
              document.export.fps == 30,
              !document.assets.isEmpty,
              !document.chapters.isEmpty
        else {
            throw TimeStoryError.storyPackageExportFailed("制作方案基础字段无效")
        }
        let allShots = document.chapters.flatMap(\.shots)
        guard let first = allShots.first,
              first.startFrame == 0,
              first.transitionIn.durationFrames == 0
        else {
            throw TimeStoryError.storyPackageExportFailed("首镜头帧边界无效")
        }
        for (index, shot) in allShots.enumerated() {
            guard shot.durationFrames > 0 else {
                throw TimeStoryError.storyPackageExportFailed("镜头帧数无效")
            }
            if index > 0 {
                let previous = allShots[index - 1]
                let expected = previous.startFrame + previous.durationFrames
                    - shot.transitionIn.durationFrames
                guard shot.startFrame == expected,
                      shot.transitionIn.durationFrames <= min(previous.durationFrames, shot.durationFrames)
                else {
                    throw TimeStoryError.storyPackageExportFailed("镜头转场重叠无效")
                }
            }
        }
        guard allShots.map({ $0.startFrame + $0.durationFrames }).max() == document.export.totalFrames else {
            throw TimeStoryError.storyPackageExportFailed("总帧数与镜头边界不一致")
        }
        let declaredIDs = Set(document.assets.map(\.assetID))
        let referencedIDs = Set(allShots.compactMap(\.assetID) + [document.audio?.assetID].compactMap { $0 })
        guard declaredIDs == referencedIDs else {
            throw TimeStoryError.storyPackageExportFailed("包含未引用素材或缺失素材")
        }
        for asset in document.assets {
            guard !asset.relativePath.hasPrefix("/"),
                  !asset.relativePath.contains("../"),
                  !asset.relativePath.contains(":")
            else {
                throw TimeStoryError.storyPackageExportFailed("素材路径不是安全相对路径")
            }
            let file = packageRoot.appendingPathComponent(asset.relativePath)
            guard FileManager.default.fileExists(atPath: file.path),
                  try fileSHA256(file) == asset.renderFileSHA256
            else {
                throw TimeStoryError.storyPackageExportFailed("素材哈希校验失败")
            }
        }
    }

    private static func publish(_ staging: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let backupName = ".imageall-story-package-\(UUID().uuidString).backup"
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: .usingNewMetadataOnly
                )
                try? fileManager.removeItem(at: parent.appendingPathComponent(backupName))
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw TimeStoryError.storyPackageExportFailed("发布失败：\(error.localizedDescription)")
        }
    }

    private static func supportedAudioType(_ url: URL) throws -> (String, String) {
        switch url.pathExtension.lowercased() {
        case "wav": ("wav", "audio/wav")
        case "mp3": ("mp3", "audio/mpeg")
        case "m4a", "mp4": (url.pathExtension.lowercased(), "audio/mp4")
        default: throw TimeStoryError.storyPackageExportFailed("配乐格式仅支持 WAV、MP3 或 M4A")
        }
    }

    private static func resolveMusicURL(_ music: TimeStoryMusicSelection) throws -> URL {
        guard let bookmark = music.securityScopedBookmark else {
            return URL(fileURLWithPath: music.filePath)
        }
        var isStale = false
        do {
            return try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw TimeStoryError.storyPackageExportFailed("无法重新取得配乐文件访问权限")
        }
    }

    static func packageProjectID(for projectID: UUID) -> String {
        opaqueID(prefix: "story", components: [projectID.uuidString])
    }

    static func packageAssetID(projectID: UUID, assetID: UUID) -> String {
        opaqueID(prefix: "photo", components: [projectID.uuidString, assetID.uuidString])
    }

    private static func opaqueID(prefix: String, components: [String]) -> String {
        "\(prefix)-\(sha256(Data(components.joined(separator: "|").lowercased().utf8)).prefix(24))"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct StoryRenderPackageDocument: Codable, Sendable, Equatable {
    var schemaVersion: String
    var projectID: String
    var projectRevision: String
    var export: Export
    var assets: [Asset]
    var chapters: [Chapter]
    var audio: Audio?
    var trace: Trace

    struct Export: Codable, Sendable, Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var totalFrames: Int
        var background: Background
        var template: Template
    }

    struct Background: Codable, Sendable, Equatable {
        var color: String
        var mode: String
        var blurPixels: Double?
        var dimOpacity: Double?
    }

    struct Template: Codable, Sendable, Equatable {
        var name: String
        var version: String
        var title: String?
        var subtitle: String?
        var closingText: String?
        var fontFamily: String?
        var textColor: String?
        var accentColor: String?
        var safeMarginRatio: Double?
    }

    struct Asset: Codable, Sendable, Equatable {
        var assetID: String
        var relativePath: String
        var mediaType: String
        var sourceContentVersion: String
        var renderFileSHA256: String
    }

    struct Chapter: Codable, Sendable, Equatable {
        var chapterID: String
        var sequenceIndex: Int
        var title: String
        var shots: [Shot]
        var trace: ChapterTrace
    }

    struct ChapterTrace: Codable, Sendable, Equatable {
        var sourceChapterID: String
        var upstreamStrategyVersion: String?
    }

    struct Shot: Codable, Sendable, Equatable {
        var shotID: String
        var sequenceIndex: Int
        var kind: String
        var assetID: String?
        var startFrame: Int
        var durationFrames: Int
        var title: String?
        var caption: Caption?
        var fit: Fit?
        var motion: Motion?
        var transitionIn: Transition
        var trace: ShotTrace
    }

    struct Caption: Codable, Sendable, Equatable { var body: String }
    struct Fit: Codable, Sendable, Equatable {
        var mode: String
        var allowCrop: Bool
    }
    struct Motion: Codable, Sendable, Equatable {
        var type: String
        var startScale: Double?
        var endScale: Double?
    }
    struct Transition: Codable, Sendable, Equatable {
        var type: String
        var durationFrames: Int
    }
    struct ShotTrace: Codable, Sendable, Equatable {
        var originalShotID: String
        var upstreamStrategyVersion: String?
    }
    struct Audio: Codable, Sendable, Equatable {
        var assetID: String
        var offsetFrame: Int
        var volume: Double
        var fadeInFrames: Int
        var fadeOutFrames: Int
        var loop: Bool
    }
    struct Trace: Codable, Sendable, Equatable {
        var upstreamPolicyVersion: String
        var exporterVersion: String?
    }
}
