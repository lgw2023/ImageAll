import AppKit
@preconcurrency import AVFoundation
import CoreText
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Story-wide typography; pixel sizes refer to a 1080-pixel short edge.
struct StoryTypography: Codable, Sendable, Equatable {
    var family = "PingFang SC"
    var titleSize: Double = 64
    var captionSize: Double = 36
    var weight: Int = 400

    func font(size: Double) -> NSFont {
        let base = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size)
        return weight >= 600 ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    var creativeConstraint: String {
        "文字样式由 ImageAll 固定：字体 \(family)，标题 \(Int(titleSize)) px，字幕 \(Int(captionSize)) px，字重 \(weight)（1080 像素短边）。保留该样式，仅优化文字内容和节奏。"
    }
}

enum TimeStoryConstants {
    static let schemaVersion = 1
    static let templateVersion = "growth-footprints-v1"
    static let strategyVersion = "time-place-balanced-v3"
    static let transitionDurationSeconds = 0.45
    static let defaultShotDurationSeconds = 3.5
    static let targetDurationSeconds = 60.0
    static let maximumShots = 18
    static let framesPerSecond: Int32 = 30
    static let preferredTransitionFrames = 14
    static let projectTitleFrames = 90
    static let chapterTitleFrames = 60
    static let outputWidth = 1_920
    static let outputHeight = 1_080
}

enum TimeStoryLocationState: String, Codable, Sendable, Equatable {
    case named
    case coordinateOnly
    case absent
    case unconfirmed
}

enum TimeStorySimilarityState: String, Codable, Sendable, Equatable {
    case ready
    case unavailable
}

struct TimeStoryCandidate: Codable, Sendable, Equatable, Identifiable {
    var id: UUID { assetID }

    let assetID: UUID
    let contentRevision: Int
    let sourceID: UUID
    let fileName: String?
    let mediaCreatedAtMs: Int64?
    let width: Int?
    let height: Int?
    let availability: AssetAvailability
    let isFavorite: Bool
    let locationState: TimeStoryLocationState
    let placeName: String?
    let locationSource: String?
    let similarityClusterID: String?
    let similarityState: TimeStorySimilarityState
    // Absent in v1 projects; the original timezone/precision is not stored in the catalog.
    var captureTimeSource: String? = nil
    var mediaKind: MediaKind? = nil
    var durationMs: Int64? = nil
    var effectiveMediaKind: MediaKind { mediaKind ?? .image }
}

struct TimeStoryCandidateSnapshot: Codable, Sendable, Equatable {
    let id: String
    let createdAtMs: Int64
    let tagID: UUID
    let tagDisplayName: String
    let candidates: [TimeStoryCandidate]
    // Counts indexed pending review suggestions, not all untagged library assets.
    var pendingReviewCount: Int? = nil
}

struct TimeStoryReadinessDetails {
    let available: Int
    let namedAssets: Int
    let analyzedAssets: Int
    let duplicateGroups: Int
    let assetsInDuplicateGroups: Int

    init(candidates: [TimeStoryCandidate]) {
        available = candidates.filter { $0.availability == .available }.count
        namedAssets = candidates.filter { $0.locationState == .named }.count
        analyzedAssets = candidates.filter { $0.similarityState == .ready }.count
        let groups = Dictionary(grouping: candidates.compactMap { candidate -> (String, UUID)? in
            guard candidate.similarityState == .ready, let cluster = candidate.similarityClusterID else { return nil }
            return (candidate.sourceID.uuidString + "|" + cluster, candidate.assetID)
        }, by: { $0.0 })
        let repeated = groups.values.filter { $0.count > 1 }
        duplicateGroups = repeated.count
        assetsInDuplicateGroups = repeated.reduce(0) { $0 + $1.count }
    }
}

struct TimeStoryReadinessSummary: Codable, Sendable, Equatable {
    let matchingCount: Int
    let reliableTimeStartMs: Int64?
    let reliableTimeEndMs: Int64?
    let unknownTimeCount: Int
    let namedPlaceCount: Int
    let coordinateOnlyCount: Int
    let noLocationCount: Int
    let locationMetadataUnconfirmedCount: Int
    let unavailableCount: Int
    let similarityFilteringState: TimeStorySimilarityState
    let selectionTradeoff: String?
}

enum TimeStoryPresentationMode: String, Codable, Sendable, Equatable, CaseIterable {
    case fullFrameWithBackground
    case aspectFitBlack
    case aspectFill

    var displayName: String {
        switch self {
        case .fullFrameWithBackground: "完整显示 · 背景填充"
        case .aspectFitBlack: "完整显示 · 黑边"
        case .aspectFill: "居中裁剪 · 铺满"
        }
    }

    func imageRect(image: CGSize, canvas: CGSize, progress: Double = 1) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let x = canvas.width / image.width, y = canvas.height / image.height
        let scale = self == .aspectFill ? max(x, y) : min(x, y)
        let motion = self == .fullFrameWithBackground ? 0.985 + 0.015 * min(1, max(0, progress)) : 1
        let size = CGSize(width: image.width * scale * motion, height: image.height * scale * motion)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Persisted source interval; ranges are half-open and audio gain is independent of music.
struct TimeStoryVideoClip: Codable, Sendable, Equatable {
    var inPointMs: Int64
    var outPointMs: Int64
    var sourceDurationMs: Int64
    var originalAudioGain: Double = 1

    struct FrameRange: Equatable, Sendable {
        let startFrame: Int64
        let endFrame: Int64
        var frameCount: Int64 { endFrame - startFrame }
    }

    func validatedFrameRange(actualDurationMs: Int64) throws -> FrameRange {
        guard actualDurationMs > 0, sourceDurationMs == actualDurationMs,
              inPointMs >= 0, outPointMs > inPointMs, outPointMs <= actualDurationMs,
              outPointMs <= (Int64.max - 999) / 30,
              originalAudioGain.isFinite, (0...1).contains(originalAudioGain) else {
            throw TimeStoryError.invalidTimeline("视频片段范围、源时长或原声音量无效")
        }
        // Quantize inward so rendering never requests outside the selected source interval.
        let range = FrameRange(startFrame: (inPointMs * 30 + 999) / 1000,
                               endFrame: outPointMs * 30 / 1000)
        guard range.frameCount > 0 else {
            throw TimeStoryError.invalidTimeline("视频片段短于一个完整的 30 fps 帧")
        }
        return range
    }
}

struct TimeStoryShot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var assetID: UUID
    var contentRevision: Int
    var chapterID: UUID
    var caption: String
    var durationSeconds: Double
    var presentationMode: TimeStoryPresentationMode
    var reasons: [String]
    var isLocked: Bool
    var isUserEdited: Bool
    // Optional fields preserve compatibility with saved stories predating field-level protection.
    var explicitLock: Bool? = nil
    var captionEdited: Bool? = nil
    var durationEdited: Bool? = nil
    // Missing in existing photo-only projects. Never infer a video from a preview image.
    var videoClip: TimeStoryVideoClip? = nil

    var hasExplicitLock: Bool {
        explicitLock ?? (isLocked && (reasons.contains("用户锁定") || !reasons.contains("手动编排")) && !reasons.contains("用户替换"))
    }
    var protectsCaption: Bool { captionEdited ?? (isUserEdited && !caption.isEmpty) }
    var protectsDuration: Bool { durationEdited ?? (isUserEdited && durationSeconds != TimeStoryConstants.defaultShotDurationSeconds) }
}

struct TimeStoryChapter: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var shotIDs: [UUID]
    var isUserEdited: Bool
}

struct TimeStoryMusicSelection: Codable, Sendable, Equatable {
    let displayName: String
    let filePath: String
    let securityScopedBookmark: Data?
    var volume: Double? = nil
}

struct TimeStoryProject: Codable, Sendable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let createdAtMs: Int64
    var updatedAtMs: Int64
    let subjectTagID: UUID
    let subjectTagDisplayName: String
    let templateVersion: String
    let strategyVersion: String
    var title: String
    var candidateSnapshot: TimeStoryCandidateSnapshot
    var readiness: TimeStoryReadinessSummary
    var chapters: [TimeStoryChapter]
    var shots: [TimeStoryShot]
    var excludedAssetIDs: Set<UUID>
    var music: TimeStoryMusicSelection?
    // Optional to decode existing v1 projects without a migration.
    var chapterTitleOverrides: [UUID: String]? = nil
    var creativeIntent: String? = nil
    var creativeTargetFrames: Int? = nil
    var creativeReceipt: StoryCreativeReceipt? = nil
    // Separate full-fidelity Atelier versions. Absent in existing projects.
    var atelierVersions: [StoryAtelierReceipt]? = nil
    var showsProjectTitle: Bool? = nil
    var showsChapterTitles: Bool? = nil
    var isFreeform: Bool? = nil
    var styleTemplate: StoryStyleSelection? = nil
    var styleReceipt: StoryStyleReceipt? = nil
    var typography: StoryTypography? = nil
    var resolvedTypography: StoryTypography { typography ?? StoryTypography() }

    func rendersChapterTitle(_ chapter: TimeStoryChapter) -> Bool {
        guard showsChapterTitles ?? true else { return false }
        // Freeform's initial chapter name is an editor placeholder, not story copy.
        return !(isFreeform == true && chapter.title.trimmingCharacters(in: .whitespacesAndNewlines) == "我的编排")
    }

    var timelineDurationSeconds: Double {
        (try? TimeStoryTimeline.normalize(project: self, allowsVideoClips: true).durationSeconds) ?? 0
    }

    var timelineFrameCount: Int {
        (try? TimeStoryTimeline.normalize(project: self).totalFrames) ?? 0
    }
}

struct TimeStoryProjectSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let subjectTagID: UUID
    let title: String
    let subjectTagDisplayName: String
    let updatedAtMs: Int64
    let durationSeconds: Double
}

enum TimeStoryError: Error, Sendable, Equatable, LocalizedError {
    case tagUnavailable
    case noCandidates
    case noReliableTime
    case projectCorrupt
    case projectNotFound
    case persistenceFailed
    case noSelectedShots
    case invalidDestination
    case invalidTimeline(String)
    case storyPackageExportFailed(String)
    case renderingFailed(String)
    case mediaValidationFailed([TimeStoryMediaValidationIssue])
    case preservedMediaChanged(String)
    case capacityConflict(Int)
    case candidateNotAddable

    var errorDescription: String? {
        switch self {
        case .tagUnavailable: "标签已不可用。"
        case .noCandidates: "这个标签还没有已确认的照片。"
        case .noReliableTime: "候选照片没有可靠拍摄时间，暂时无法建立成长顺序。"
        case .projectCorrupt: "故事项目无法读取。"
        case .projectNotFound: "故事项目不存在。"
        case .persistenceFailed: "故事项目未能保存。"
        case .noSelectedShots: "故事中没有可导出的镜头。"
        case .invalidDestination: "导出位置不可用。"
        case let .invalidTimeline(message): "故事时间线无效：\(message)"
        case let .storyPackageExportFailed(message): "故事包导出失败：\(message)"
        case let .renderingFailed(message): "视频导出失败：\(message)"
        case let .mediaValidationFailed(issues):
            "有 \(issues.count) 个镜头的素材已变化或不可用。"
        case let .preservedMediaChanged(asset):
            "保留的镜头 \(asset) 已失效、改版或不再属于主体标签；请解锁、排除或重新选择后再生成。"
        case let .capacityConflict(count):
            "有 \(count) 个锁定或手动修改镜头，超过 18 个镜头容量；请解锁或排除至少 \(count - 18) 个。"
        case .candidateNotAddable:
            "该照片不符合当前操作条件。请选择当前素材库中可用、未加入且未排除的照片。"
        }
    }
}

struct TimeStoryMediaValidationIssue: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case missing
        case unavailable
        case versionChanged
    }

    var id: String { "\(shotIndex)-\(assetID.uuidString)-\(kind.rawValue)" }
    let shotIndex: Int
    let assetID: UUID
    let kind: Kind
    let expectedRevision: Int
    let actualRevision: Int?
}

enum TimeStoryFrameSegmentKind: String, Sendable, Equatable {
    case projectTitle
    case chapterTitle
    case photo
}

struct TimeStoryFrameSegment: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: TimeStoryFrameSegmentKind
    let chapterID: UUID
    let shotID: UUID?
    let assetID: UUID?
    let title: String?
    let caption: String?
    let startFrame: Int
    let durationFrames: Int
    let transitionInFrames: Int

    var presentationMode: TimeStoryPresentationMode = .fullFrameWithBackground

    var endFrame: Int { startFrame + durationFrames }
}

struct TimeStoryFrameTimeline: Sendable, Equatable {
    let fps: Int
    let segments: [TimeStoryFrameSegment]
    let totalFrames: Int

    var durationSeconds: Double { Double(totalFrames) / Double(fps) }

    func state(atFrame requestedFrame: Int) -> TimeStoryTimelineState? {
        guard !segments.isEmpty else { return nil }
        let frame = min(max(0, requestedFrame), max(0, totalFrames - 1))
        var index = segments.count - 1
        for candidate in segments.indices {
            if frame < segments[candidate].endFrame || candidate == segments.count - 1 {
                index = candidate
                break
            }
        }
        let segment = segments[index]
        let localFrame = max(0, frame - segment.startFrame)
        let next = index + 1 < segments.count ? segments[index + 1] : nil
        let overlap = next?.transitionInFrames ?? 0
        let transitionStart = max(0, segment.durationFrames - overlap)
        let blend: Double
        let transitioningTo: TimeStoryFrameSegment?
        if let next, overlap > 0, localFrame >= transitionStart {
            blend = min(1, Double(localFrame - transitionStart) / Double(overlap))
            transitioningTo = next
        } else {
            blend = 0
            transitioningTo = nil
        }
        return TimeStoryTimelineState(
            current: segment,
            next: transitioningTo,
            blend: blend,
            progress: Double(localFrame) / Double(max(1, segment.durationFrames - 1))
        )
    }
}

enum TimeStoryTimeline {
    /// Converts the persisted v1 second-based project into the sole authoritative
    /// render timeline. Persisted values are never rewritten by this operation.
    static func normalize(project: TimeStoryProject, allowsVideoClips: Bool = false) throws -> TimeStoryFrameTimeline {
        guard !project.shots.isEmpty else { throw TimeStoryError.noSelectedShots }
        guard allowsVideoClips || project.shots.allSatisfy({ $0.videoClip == nil }) else {
            throw TimeStoryError.invalidTimeline("视频片段渲染尚未启用，不能作为静态照片导出")
        }
        guard !project.chapters.isEmpty else {
            throw TimeStoryError.invalidTimeline("没有章节")
        }

        let flattenedShotIDs = project.chapters.flatMap(\.shotIDs)
        let orderedShotIDs = project.shots.map(\.id)
        guard flattenedShotIDs == orderedShotIDs,
              Set(flattenedShotIDs).count == flattenedShotIDs.count
        else {
            throw TimeStoryError.invalidTimeline("章节镜头顺序与项目镜头顺序不一致")
        }

        var drafts: [(kind: TimeStoryFrameSegmentKind, id: UUID, chapterID: UUID, shotID: UUID?, assetID: UUID?, title: String?, caption: String?, duration: Int)] = []
        guard let firstChapterID = project.chapters.first?.id else {
            throw TimeStoryError.invalidTimeline("没有可呈现的章节")
        }
        let projectTitle = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.showsProjectTitle ?? true {
        drafts.append((
            .projectTitle,
            TimeStoryStableID.uuid("render-title|\(project.id.uuidString.lowercased())"),
            firstChapterID,
            nil,
            nil,
            projectTitle.isEmpty ? project.subjectTagDisplayName : projectTitle,
            nil,
            TimeStoryConstants.projectTitleFrames
        ))
        }

        for chapter in project.chapters {
            let chapterTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chapterTitle.isEmpty else {
                throw TimeStoryError.invalidTimeline("章节标题不能为空")
            }
            if project.rendersChapterTitle(chapter) {
            drafts.append((
                .chapterTitle,
                TimeStoryStableID.uuid("render-chapter|\(project.id.uuidString.lowercased())|\(chapter.id.uuidString.lowercased())"),
                chapter.id,
                nil,
                nil,
                chapterTitle,
                nil,
                TimeStoryConstants.chapterTitleFrames
            ))
            }
            for shotID in chapter.shotIDs {
                guard let shot = project.shots.first(where: { $0.id == shotID }),
                      shot.chapterID == chapter.id
                else {
                    throw TimeStoryError.invalidTimeline("章节包含未知镜头")
                }
                guard shot.durationSeconds.isFinite, shot.durationSeconds > 0 else {
                    throw TimeStoryError.invalidTimeline("镜头时长必须为有限正数")
                }
                let quantized: Int
                if let clip = shot.videoClip {
                    quantized = Int(try clip.validatedFrameRange(actualDurationMs: clip.sourceDurationMs).frameCount)
                } else {
                    quantized = Int((shot.durationSeconds * Double(TimeStoryConstants.framesPerSecond)).rounded(.toNearestOrAwayFromZero))
                }
                guard quantized > 0 else {
                    throw TimeStoryError.invalidTimeline("镜头时长短于一个 30 fps 帧")
                }
                drafts.append((
                    .photo,
                    TimeStoryStableID.uuid("render-photo|\(project.id.uuidString.lowercased())|\(shot.id.uuidString.lowercased())"),
                    chapter.id,
                    shot.id,
                    shot.assetID,
                    nil,
                    shot.caption,
                    quantized
                ))
            }
        }

        var segments: [TimeStoryFrameSegment] = []
        for draft in drafts {
            let overlap: Int
            let start: Int
            if let previous = segments.last {
                overlap = min(
                    TimeStoryConstants.preferredTransitionFrames,
                    max(0, previous.durationFrames - 1),
                    max(0, draft.duration - 1),
                    90
                )
                start = previous.endFrame - overlap
            } else {
                overlap = 0
                start = 0
            }
            segments.append(TimeStoryFrameSegment(
                id: draft.id,
                kind: draft.kind,
                chapterID: draft.chapterID,
                shotID: draft.shotID,
                assetID: draft.assetID,
                title: draft.title,
                caption: draft.caption,
                startFrame: start,
                durationFrames: draft.duration,
                transitionInFrames: overlap,
                presentationMode: project.shots.first(where: { $0.id == draft.shotID })?.presentationMode ?? .fullFrameWithBackground
            ))
        }
        guard let totalFrames = segments.map(\.endFrame).max(), totalFrames > 0 else {
            throw TimeStoryError.invalidTimeline("总帧数无效")
        }
        return TimeStoryFrameTimeline(
            fps: Int(TimeStoryConstants.framesPerSecond),
            segments: segments,
            totalFrames: totalFrames
        )
    }
}

struct TimeStoryTimelineState: Sendable, Equatable {
    let current: TimeStoryFrameSegment
    let next: TimeStoryFrameSegment?
    let blend: Double
    let progress: Double
}

struct TimeStoryCandidateProvider: Sendable {
    let database: CatalogDatabase
    let query: any AssetCatalogQueryPort

    func snapshot(
        tag: TagListItem,
        nowMs: Int64,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) throws -> TimeStoryCandidateSnapshot {
        guard tag.state == .active else { throw TimeStoryError.tagUnavailable }
        var cursor: AssetPageCursor?
        var projections: [AssetGridItemProjection] = []
        var observedCursors = Set<String>()
        var seenAssetIDs = Set<UUID>()
        repeat {
            try Task<Never, Never>.checkCancellation()
            let page = try query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(
                        tagDecisionFilters: [
                            TagDecisionFilter(tagID: tag.id, decision: .accepted),
                        ],
                        availabilities: [.available, .missing, .unreadable, .unsupported],
                        mediaKinds: [.image, .video]
                    ),
                    sort: .embeddedTimeOldest,
                    cursor: cursor,
                    limit: 200
                )
            )
            guard page.items.allSatisfy({ seenAssetIDs.insert($0.assetID).inserted }) else {
                throw TimeStoryError.persistenceFailed
            }
            projections.append(contentsOf: page.items)
            onProgress?(projections.count)
            cursor = page.nextCursor
            if let cursor {
                let marker = String(describing: cursor)
                guard observedCursors.insert(marker).inserted else {
                    throw TimeStoryError.persistenceFailed
                }
            }
        } while cursor != nil

        let candidates = try metadataCandidates(for: projections)
        let pending = try pendingReviewCount(for: tag.id)
        let canonicalCandidates = candidates.sorted {
            if $0.mediaCreatedAtMs != $1.mediaCreatedAtMs {
                switch ($0.mediaCreatedAtMs, $1.mediaCreatedAtMs) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return $0.assetID.uuidString < $1.assetID.uuidString
        }
        var digestPayload = Data(
            "tag=\(tag.id.uuidString.lowercased())\nstrategy=\(TimeStoryConstants.strategyVersion)\n".utf8
        )
        digestPayload.append(try JSONEncoder.timeStory.encode(canonicalCandidates))
        digestPayload.append(Data("\npending=\(pending)".utf8))
        let digest = SHA256.hash(data: digestPayload).map { String(format: "%02x", $0) }.joined()
        return TimeStoryCandidateSnapshot(
            id: "sha256:\(digest)",
            createdAtMs: nowMs,
            tagID: tag.id,
            tagDisplayName: tag.displayName,
            candidates: canonicalCandidates,
            pendingReviewCount: pending
        )
    }

    private func pendingReviewCount(for tagID: UUID) throws -> Int {
        let id = tagID.uuidString.lowercased()
        return try database.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT p.asset_id FROM personal_prediction p
                    JOIN asset a ON a.id = p.asset_id AND a.content_revision = p.content_revision
                    WHERE p.tag_id = ? AND p.state = 'pendingReview'
                    UNION
                    SELECT p.asset_id FROM standard_prediction p
                    JOIN asset a ON a.id = p.asset_id AND a.content_revision = p.content_revision
                    WHERE p.tag_id = ? AND p.state = 'pendingReview'
                    UNION
                    SELECT m.asset_id FROM contextual_tag_feed_member m
                    JOIN contextual_tag_feed f ON f.id = m.feed_id
                    WHERE f.tag_id = ? AND f.state = 'pending' AND m.role = 'candidate'
                ) suggestions
                JOIN asset a ON a.id = suggestions.asset_id
                WHERE a.locator_state = 'current' AND a.media_kind IN ('image', 'video')
                  AND NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = a.id AND d.tag_id = ?
                  )
                """, arguments: [id, id, id, id]) ?? 0
        }
    }

    private func metadataCandidates(
        for projections: [AssetGridItemProjection]
    ) throws -> [TimeStoryCandidate] {
        let ids = projections.map(\.assetID)
        var rowsByID: [UUID: Row] = [:]
        for batchStart in stride(from: 0, to: ids.count, by: 400) {
            try Task<Never, Never>.checkCancellation()
            let batch = Array(ids[batchStart ..< min(ids.count, batchStart + 400)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let arguments = StatementArguments(batch.map { $0.uuidString.lowercased() })
            let rows = try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id, asset.locator_kind, asset.media_kind, asset.duration_ms,
                           favorite.desired_value,
                           favorite.photos_observed_value,
                           location.source_kind AS location_source_kind,
                           location.latitude,
                           location.longitude,
                           place.canonical_name AS place_name,
                           similarity.cluster_id,
                           similarity.content_revision AS similarity_revision,
                           similarity_index.state AS similarity_index_state
                    FROM asset
                    LEFT JOIN asset_favorite_state favorite ON favorite.asset_id = asset.id
                    LEFT JOIN asset_location location ON location.asset_id = asset.id
                    LEFT JOIN place ON place.id = location.place_id
                    LEFT JOIN source_similarity_bucket_member similarity
                      ON similarity.asset_id = asset.id AND similarity.media_kind = asset.media_kind
                    LEFT JOIN source_similarity_index similarity_index
                      ON similarity_index.source_id = similarity.source_id
                     AND similarity_index.media_kind = similarity.media_kind
                    WHERE asset.id IN (\(placeholders))
                    """,
                    arguments: arguments
                )
            }
            for row in rows {
                if let rawID: String = row["id"], let id = UUID(uuidString: rawID) {
                    rowsByID[id] = row
                }
            }
        }
        return try projections.map { projection in
            guard let metadata = rowsByID[projection.assetID] else {
                throw TimeStoryError.persistenceFailed
            }
            let locationSource: String? = metadata["location_source_kind"]
            let latitude: Double? = metadata["latitude"]
            let longitude: Double? = metadata["longitude"]
            let placeName: String? = metadata["place_name"]
            let locationState: TimeStoryLocationState
            if let placeName, !placeName.isEmpty {
                locationState = .named
            } else if locationSource == nil {
                locationState = .unconfirmed
            } else if locationSource == "none" {
                locationState = .absent
            } else if latitude != nil, longitude != nil {
                locationState = .coordinateOnly
            } else {
                locationState = .unconfirmed
            }
            let desired: Int? = metadata["desired_value"]
            let observed: Int? = metadata["photos_observed_value"]
            let similarityRevision: Int? = metadata["similarity_revision"]
            let similarityIndexState: String? = metadata["similarity_index_state"]
            let similarityReady = similarityIndexState == "ready"
                && similarityRevision == projection.contentRevision
            var candidate = TimeStoryCandidate(
                assetID: projection.assetID,
                contentRevision: projection.contentRevision,
                sourceID: projection.sourceID,
                fileName: projection.fileName,
                mediaCreatedAtMs: projection.mediaCreatedAtMs,
                width: projection.width,
                height: projection.height,
                availability: projection.availability,
                isFavorite: desired == 1 || observed == 1,
                locationState: locationState,
                placeName: locationState == .named ? placeName : nil,
                locationSource: locationSource,
                similarityClusterID: similarityReady ? metadata["cluster_id"] : nil,
                similarityState: similarityReady ? .ready : .unavailable
            )
            candidate.mediaKind = MediaKind(rawValue: metadata["media_kind"])
            candidate.durationMs = metadata["duration_ms"]
            let locator: String? = metadata["locator_kind"]
            if candidate.mediaCreatedAtMs != nil {
                candidate.captureTimeSource = locator == "photos" ? "PhotoKit creationDate"
                    : locator == "file" ? "有时区的文件媒体时间" : nil
            }
            return candidate
        }
    }
}

struct TimeStoryPlanner: Sendable {
    func makeProject(
        snapshot: TimeStoryCandidateSnapshot,
        nowMs: Int64,
        existing: TimeStoryProject? = nil
    ) throws -> TimeStoryProject {
        let allCandidates = snapshot.candidates
        guard !allCandidates.isEmpty else { throw TimeStoryError.noCandidates }
        let reliable = allCandidates.filter {
            $0.mediaCreatedAtMs != nil && ($0.effectiveMediaKind == .image || ($0.durationMs ?? 0) >= 34)
        }
        guard !reliable.isEmpty else { throw TimeStoryError.noReliableTime }
        let selectable = reliable.filter { $0.availability == .available }
        guard !selectable.isEmpty else { throw TimeStoryError.noSelectedShots }

        let excluded = existing?.excludedAssetIDs ?? []
        let candidateByID = Dictionary(uniqueKeysWithValues: allCandidates.map { ($0.assetID, $0) })
        let preservedShots = (existing?.shots ?? []).filter { ($0.isLocked || $0.isUserEdited) && !excluded.contains($0.assetID) }
        if preservedShots.count > TimeStoryConstants.maximumShots {
            throw TimeStoryError.capacityConflict(preservedShots.count)
        }
        for shot in preservedShots {
            guard let candidate = candidateByID[shot.assetID],
                  candidate.availability == .available,
                  candidate.mediaCreatedAtMs != nil,
                  candidate.contentRevision == shot.contentRevision
            else { throw TimeStoryError.preservedMediaChanged(String(shot.assetID.uuidString.prefix(8))) }
            if let clip = shot.videoClip {
                guard candidate.effectiveMediaKind == .video, let duration = candidate.durationMs else {
                    throw TimeStoryError.preservedMediaChanged(String(shot.assetID.uuidString.prefix(8)))
                }
                _ = try clip.validatedFrameRange(actualDurationMs: duration)
            }
        }
        let preservedIDs = Set(preservedShots.map(\.assetID))
        let preservedCandidates = preservedShots.compactMap { candidateByID[$0.assetID] }
        let storyTimeBounds = timeBounds(reliable)
        let selected = selectCandidates(
            selectable.filter { !excluded.contains($0.assetID) && !preservedIDs.contains($0.assetID) },
            limit: TimeStoryConstants.maximumShots,
            preserving: preservedCandidates,
            bounds: storyTimeBounds
        )

        var preservedByAssetID = Dictionary(grouping: preservedShots, by: \.assetID)
        var shots = try selected.map { candidate -> TimeStoryShot in
            if var old = preservedByAssetID[candidate.assetID]?.first {
                preservedByAssetID[candidate.assetID]?.removeFirst()
                if old.isLocked && !old.reasons.contains("用户锁定") { old.reasons.append("用户锁定") }
                return old
            }
            let clip: TimeStoryVideoClip? = candidate.effectiveMediaKind == .video
                ? .init(inPointMs: 0, outPointMs: min(candidate.durationMs!, 3500),
                        sourceDurationMs: candidate.durationMs!, originalAudioGain: 1) : nil
            let frames = try clip.map { try $0.validatedFrameRange(actualDurationMs: $0.sourceDurationMs).frameCount }
            return TimeStoryShot(
                id: TimeStoryStableID.uuid("shot|\(candidate.assetID.uuidString.lowercased())"),
                assetID: candidate.assetID,
                contentRevision: candidate.contentRevision,
                chapterID: UUID(),
                caption: candidate.placeName ?? snapshot.tagDisplayName,
                durationSeconds: frames.map { Double($0) / 30 } ?? TimeStoryConstants.defaultShotDurationSeconds,
                presentationMode: .fullFrameWithBackground,
                reasons: reasons(for: candidate, among: selected, bounds: storyTimeBounds)
                    + (clip == nil ? [] : ["自动片段：开头最多3.5秒，可编辑范围与原声"]),
                isLocked: false,
                isUserEdited: false,
                videoClip: clip
            )
        }

        let chapterDrafts = makeChapterDrafts(selected, bounds: storyTimeBounds)
        let oldChaptersByID = Dictionary(uniqueKeysWithValues: (existing?.chapters ?? []).map { ($0.id, $0) })
        var chapters: [TimeStoryChapter] = []
        var remainingShotIDs = Dictionary(grouping: shots, by: \.assetID).mapValues { $0.map(\.id) }
        for draft in chapterDrafts {
            let chapterID = TimeStoryStableID.uuid("chapter|\(draft.key)")
            let shotIDs = draft.assetIDs.compactMap { assetID -> UUID? in
                guard let first = remainingShotIDs[assetID]?.first else { return nil }
                remainingShotIDs[assetID]?.removeFirst()
                return first
            }
            let old = oldChaptersByID[chapterID]
            chapters.append(
                TimeStoryChapter(
                    id: chapterID,
                    title: existing?.chapterTitleOverrides?[chapterID]
                        ?? (old?.isUserEdited == true ? old!.title : draft.title),
                    shotIDs: shotIDs,
                    isUserEdited: existing?.chapterTitleOverrides?[chapterID] != nil || old?.isUserEdited == true
                )
            )
            for index in shots.indices where shotIDs.contains(shots[index].id) {
                shots[index].chapterID = chapterID
            }
        }

        let readiness = readiness(for: snapshot, selectedCount: selected.count)
        return TimeStoryProject(
            schemaVersion: TimeStoryConstants.schemaVersion,
            id: existing?.id ?? UUID(),
            createdAtMs: existing?.createdAtMs ?? nowMs,
            updatedAtMs: nowMs,
            subjectTagID: snapshot.tagID,
            subjectTagDisplayName: snapshot.tagDisplayName,
            templateVersion: TimeStoryConstants.templateVersion,
            strategyVersion: TimeStoryConstants.strategyVersion,
            title: existing?.title ?? "\(snapshot.tagDisplayName) · 成长与足迹",
            candidateSnapshot: snapshot,
            readiness: readiness,
            chapters: chapters,
            shots: shots,
            excludedAssetIDs: excluded,
            music: existing?.music,
            chapterTitleOverrides: existing?.chapterTitleOverrides
        )
    }

    func makeFreeformProject(snapshot: TimeStoryCandidateSnapshot, nowMs: Int64) -> TimeStoryProject {
        TimeStoryProject(schemaVersion: TimeStoryConstants.schemaVersion, id: UUID(),
            createdAtMs: nowMs, updatedAtMs: nowMs, subjectTagID: snapshot.tagID,
            subjectTagDisplayName: snapshot.tagDisplayName, templateVersion: "freeform-v1",
            strategyVersion: "manual-v1", title: snapshot.tagDisplayName,
            candidateSnapshot: snapshot, readiness: readiness(for: snapshot, selectedCount: 0),
            chapters: [], shots: [], excludedAssetIDs: [], music: nil,
            showsProjectTitle: false, showsChapterTitles: false, isFreeform: true)
    }

    func readiness(for snapshot: TimeStoryCandidateSnapshot, selectedCount: Int? = nil) -> TimeStoryReadinessSummary {
        let allCandidates = snapshot.candidates
        let reliable = allCandidates.filter { $0.mediaCreatedAtMs != nil }
        let namedPlaces = Set(allCandidates.compactMap(\.placeName))
        let similarityReady = allCandidates.contains(where: { $0.similarityState == .ready })
        let tradeoff: String?
        if let selectedCount, reliable.count > selectedCount {
            tradeoff = "选取 \(selectedCount) 张，另有 \(reliable.count - selectedCount) 张可靠时间素材未进入草稿（含不可用/排除）。"
        } else if allCandidates.count > reliable.count {
            tradeoff = "有 \(allCandidates.count - reliable.count) 张时间未知素材留在待确认区。"
        } else {
            tradeoff = nil
        }
        return TimeStoryReadinessSummary(
            matchingCount: allCandidates.count,
            reliableTimeStartMs: reliable.compactMap(\.mediaCreatedAtMs).min(),
            reliableTimeEndMs: reliable.compactMap(\.mediaCreatedAtMs).max(),
            unknownTimeCount: allCandidates.filter { $0.mediaCreatedAtMs == nil }.count,
            namedPlaceCount: namedPlaces.count,
            coordinateOnlyCount: allCandidates.filter { $0.locationState == .coordinateOnly }.count,
            noLocationCount: allCandidates.filter { $0.locationState == .absent }.count,
            locationMetadataUnconfirmedCount: allCandidates.filter { $0.locationState == .unconfirmed }.count,
            unavailableCount: allCandidates.filter { $0.availability != .available }.count,
            similarityFilteringState: similarityReady ? .ready : .unavailable,
            selectionTradeoff: tradeoff
        )
    }

    private func selectCandidates(
        _ candidates: [TimeStoryCandidate],
        limit: Int,
        preserving preserved: [TimeStoryCandidate],
        bounds: (start: Int64, end: Int64)?
    ) -> [TimeStoryCandidate] {
        guard limit > 0 else { return [] }
        let ordered = candidates.sorted(by: candidateTimeOrder)
        let stages = Dictionary(grouping: ordered) { stageKey($0, bounds: bounds) }
        var selected = preserved
        var selectedIDs = Set(preserved.map(\.assetID))
        func append(_ candidate: TimeStoryCandidate?) {
            guard let candidate, selected.count < limit, selectedIDs.insert(candidate.assetID).inserted else { return }
            selected.append(candidate)
        }

        for key in [0, 1, 2] {
            if !selected.contains(where: { stageKey($0, bounds: bounds) == key }) {
                append(stages[key]?.max(by: { selectionScore($0) < selectionScore($1) }))
            }
        }
        var previousPlace: String?
        for candidate in ordered {
            if let place = candidate.placeName, place != previousPlace {
                append(candidate)
                previousPlace = place
            }
        }
        let ranked = ordered.sorted {
            let lhs = selectionScore($0)
            let rhs = selectionScore($1)
            if lhs != rhs { return lhs > rhs }
            return candidateTimeOrder($0, $1)
        }
        func appendIfDistinct(_ candidate: TimeStoryCandidate) -> Bool {
            guard !selectedIDs.contains(candidate.assetID),
                  let time = candidate.mediaCreatedAtMs
            else { return false }
            // Without a compatible similarity result, a burst of favorites can
            // otherwise consume most of the story. Two within a rolling day
            // preserve room for a meaningful same-day comparison.
            let withinDay = selected.filter {
                guard let chosenTime = $0.mediaCreatedAtMs else { return false }
                return abs(time - chosenTime) < 24 * 60 * 60 * 1_000
            }.count
            guard withinDay < 2 else { return false }
            let isNearDuplicate = selected.contains { chosen in
                guard candidate.similarityState == .ready,
                      chosen.similarityState == .ready,
                      candidate.similarityClusterID != nil,
                      candidate.similarityClusterID == chosen.similarityClusterID,
                      stageKey(candidate, bounds: bounds) == stageKey(chosen, bounds: bounds),
                      let lhs = candidate.mediaCreatedAtMs,
                      let rhs = chosen.mediaCreatedAtMs
                else { return false }
                return abs(lhs - rhs) <= 6 * 60 * 60 * 1_000
            }
            guard !isNearDuplicate else { return false }
            append(candidate)
            return true
        }
        // A populated period gets several opportunities before quality scores
        // fill the remaining seats; sparse periods are never padded artificially.
        for key in [0, 1, 2] {
            for candidate in ranked where stageKey(candidate, bounds: bounds) == key {
                guard selected.count < limit else { break }
                if selected.filter({ stageKey($0, bounds: bounds) == key }).count >= 3 { break }
                _ = appendIfDistinct(candidate)
            }
        }
        func nearestSelectedDays(_ candidate: TimeStoryCandidate) -> Int64 {
            guard let time = candidate.mediaCreatedAtMs else { return 0 }
            return selected.compactMap { chosen in
                chosen.mediaCreatedAtMs.map { abs(time - $0) / 86_400_000 }
            }.min() ?? Int64.max
        }
        while selected.count < limit {
            // After stage coverage, the next seat goes to a different capture
            // period. Quality chooses between similarly distant windows.
            let byTimeCoverage = ranked.sorted { lhs, rhs in
                let lhsGap = nearestSelectedDays(lhs)
                let rhsGap = nearestSelectedDays(rhs)
                if lhsGap != rhsGap { return lhsGap > rhsGap }
                let lhsScore = selectionScore(lhs)
                let rhsScore = selectionScore(rhs)
                return lhsScore == rhsScore ? candidateTimeOrder(lhs, rhs) : lhsScore > rhsScore
            }
            guard byTimeCoverage.contains(where: appendIfDistinct) else { break }
        }
        // Empty seats are preferable to repeating one capture event solely to fill a quota.
        return selected.sorted(by: candidateTimeOrder)
    }

    private func selectionScore(_ candidate: TimeStoryCandidate) -> Int64 {
        let pixels = Int64(max(0, candidate.width ?? 0)) * Int64(max(0, candidate.height ?? 0))
        return (candidate.availability == .available ? 1_000_000_000 : 0)
            + (candidate.isFavorite ? 100_000_000 : 0)
            + (candidate.placeName == nil ? 0 : 10_000_000)
            + min(pixels, 9_000_000)
    }

    private func reasons(
        for candidate: TimeStoryCandidate,
        among selected: [TimeStoryCandidate],
        bounds: (start: Int64, end: Int64)?
    ) -> [String] {
        var result: [String] = []
        let stage = stageKey(candidate, bounds: bounds)
        let stageMembers = selected.filter { stageKey($0, bounds: bounds) == stage }
        if stageMembers.first?.assetID == candidate.assetID {
            result.append(["最早已知阶段代表", "中期阶段代表", "近期阶段代表"][stage])
        } else {
            result.append("同阶段可用照片")
        }
        if candidate.isFavorite { result.append("收藏照片") }
        if let place = candidate.placeName,
           let index = selected.firstIndex(where: { $0.assetID == candidate.assetID }),
           (index == 0 || selected[index - 1].placeName != place) {
            result.append("该地点连续段的首张")
        }
        return result
    }

    func replacementCandidates(for shotID: UUID, in project: TimeStoryProject) -> [TimeStoryCandidate] {
        guard let shot = project.shots.first(where: { $0.id == shotID }),
              let original = project.candidateSnapshot.candidates.first(where: { $0.assetID == shot.assetID })
        else { return [] }
        let bounds = timeBounds(project.candidateSnapshot.candidates.filter { $0.mediaCreatedAtMs != nil })
        let stage = stageKey(original, bounds: bounds)
        let used = Set(project.shots.filter { $0.id != shotID }.map(\.assetID))
        return project.candidateSnapshot.candidates.filter {
            $0.effectiveMediaKind == .image && $0.assetID != original.assetID
                && $0.mediaCreatedAtMs != nil
                && $0.availability == .available
                && stageKey($0, bounds: bounds) == stage
                && $0.placeName == original.placeName
                && !used.contains($0.assetID)
                && !project.excludedAssetIDs.contains($0.assetID)
        }.sorted(by: candidateTimeOrder)
    }

    func addableCandidates(in project: TimeStoryProject) -> [TimeStoryCandidate] {
        guard project.shots.count < TimeStoryConstants.maximumShots,
              project.chapters.count == 1,
              let first = project.shots.first,
              project.shots.allSatisfy({ $0.chapterID == project.chapters[0].id }),
              let anchor = project.candidateSnapshot.candidates.first(where: { $0.assetID == first.assetID })
        else { return [] }
        let used = Set(project.shots.map(\.assetID))
        return project.candidateSnapshot.candidates.filter {
            $0.effectiveMediaKind == .image && $0.availability == .available
                && $0.mediaCreatedAtMs != nil
                && $0.placeName == anchor.placeName
                && !used.contains($0.assetID)
                && !project.excludedAssetIDs.contains($0.assetID)
        }.sorted(by: candidateTimeOrder)
    }

    func appending(_ candidate: TimeStoryCandidate, to project: TimeStoryProject, nowMs: Int64) throws -> TimeStoryProject {
        guard addableCandidates(in: project).contains(candidate) else {
            throw TimeStoryError.candidateNotAddable
        }
        var updated = project
        let chapterID = updated.chapters[0].id
        updated.shots.append(TimeStoryShot(
            id: TimeStoryStableID.uuid("shot|\(candidate.assetID.uuidString.lowercased())"),
            assetID: candidate.assetID,
            contentRevision: candidate.contentRevision,
            chapterID: chapterID,
            caption: "",
            durationSeconds: TimeStoryConstants.defaultShotDurationSeconds,
            presentationMode: .fullFrameWithBackground,
            reasons: ["人工补选候选"],
            isLocked: false,
            isUserEdited: false
        ))
        let byID = Dictionary(uniqueKeysWithValues: updated.candidateSnapshot.candidates.map { ($0.assetID, $0) })
        updated.shots.sort { lhs, rhs in
            guard let left = byID[lhs.assetID], let right = byID[rhs.assetID] else {
                return lhs.assetID.uuidString < rhs.assetID.uuidString
            }
            return candidateTimeOrder(left, right)
        }
        updated.chapters[0].shotIDs = updated.shots.map(\.id)
        updated.readiness = readiness(for: updated.candidateSnapshot, selectedCount: updated.shots.count)
        updated.updatedAtMs = nowMs
        return updated
    }

    /// Manual montage uses confirmed snapshot members, without inventing time/place facts.
    func manuallyEditableCandidates(in project: TimeStoryProject, replacing shotID: UUID? = nil) -> [TimeStoryCandidate] {
        let used = Set(project.shots.filter { $0.id != shotID }.map(\.assetID))
        return project.candidateSnapshot.candidates.filter {
            $0.availability == .available
                && (shotID == nil || $0.effectiveMediaKind == .image)
                && ($0.effectiveMediaKind == .video ? ($0.durationMs ?? 0) > 0 : !used.contains($0.assetID))
                && !project.excludedAssetIDs.contains($0.assetID)
        }.sorted(by: candidateTimeOrder)
    }

    func manuallyInserting(_ candidate: TimeStoryCandidate, before targetID: UUID? = nil,
                           in project: TimeStoryProject, nowMs: Int64, videoClip: TimeStoryVideoClip? = nil) throws -> TimeStoryProject {
        guard manuallyEditableCandidates(in: project).contains(candidate),
              targetID == nil || project.shots.contains(where: { $0.id == targetID })
        else { throw TimeStoryError.candidateNotAddable }
        let duration: Double
        if candidate.effectiveMediaKind == .video {
            guard let videoClip, let sourceDuration = candidate.durationMs else {
                throw TimeStoryError.invalidTimeline("请先为视频选择片段范围")
            }
            duration = Double(try videoClip.validatedFrameRange(actualDurationMs: sourceDuration).frameCount) / 30
        } else {
            guard videoClip == nil else { throw TimeStoryError.candidateNotAddable }
            duration = TimeStoryConstants.defaultShotDurationSeconds
        }
        var updated = project
        let target = targetID.flatMap { id in updated.shots.first(where: { $0.id == id }) }
        let chapterID = target?.chapterID ?? updated.chapters.last?.id ?? UUID()
        if updated.chapters.isEmpty {
            updated.chapters = [TimeStoryChapter(id: chapterID, title: "我的编排", shotIDs: [], isUserEdited: true)]
        }
        let shot = TimeStoryShot(id: UUID(), assetID: candidate.assetID,
            contentRevision: candidate.contentRevision, chapterID: chapterID, caption: "",
            durationSeconds: duration,
            presentationMode: .fullFrameWithBackground, reasons: ["手动编排"], isLocked: false, isUserEdited: true, explicitLock: false, captionEdited: false, durationEdited: false, videoClip: videoClip)
        let index = targetID.flatMap { id in updated.shots.firstIndex(where: { $0.id == id }) } ?? updated.shots.endIndex
        updated.shots.insert(shot, at: index)
        for index in updated.chapters.indices {
            updated.chapters[index].shotIDs = updated.shots.filter { $0.chapterID == updated.chapters[index].id }.map(\.id)
        }
        updated.readiness = readiness(for: updated.candidateSnapshot, selectedCount: updated.shots.count)
        updated.updatedAtMs = nowMs
        return updated
    }

    func moving(_ shotID: UUID, before targetID: UUID?, in project: TimeStoryProject, nowMs: Int64) throws -> TimeStoryProject {
        guard !project.chapters.isEmpty, shotID != targetID, let source = project.shots.firstIndex(where: { $0.id == shotID }),
              targetID == nil || project.shots.contains(where: { $0.id == targetID })
        else { throw TimeStoryError.candidateNotAddable }
        var updated = project
        var shot = updated.shots.remove(at: source)
        let targetIndex = targetID.flatMap { id in updated.shots.firstIndex(where: { $0.id == id }) } ?? updated.shots.endIndex
        shot.chapterID = targetID.flatMap { id in updated.shots.first(where: { $0.id == id })?.chapterID }
            ?? updated.chapters.last!.id
        shot.isUserEdited = true
        updated.shots.insert(shot, at: targetIndex)
        for index in updated.chapters.indices {
            updated.chapters[index].shotIDs = updated.shots.filter { $0.chapterID == updated.chapters[index].id }.map(\.id)
        }
        updated.chapters.removeAll { $0.shotIDs.isEmpty }
        updated.updatedAtMs = nowMs
        return updated
    }

    private func timeBounds(_ candidates: [TimeStoryCandidate]) -> (start: Int64, end: Int64)? {
        let times = candidates.compactMap(\.mediaCreatedAtMs)
        guard let start = times.min(), let end = times.max() else { return nil }
        return (start, end)
    }

    private func stageKey(
        _ candidate: TimeStoryCandidate,
        bounds: (start: Int64, end: Int64)?
    ) -> Int {
        guard let time = candidate.mediaCreatedAtMs,
              let bounds,
              bounds.end > bounds.start
        else { return 1 }
        let fraction = Double(time - bounds.start) / Double(bounds.end - bounds.start)
        if fraction < 1.0 / 3.0 { return 0 }
        if fraction >= 2.0 / 3.0 { return 2 }
        return 1
    }

    private struct ChapterDraft {
        let key: String
        let title: String
        var assetIDs: [UUID]
    }

    private func makeChapterDrafts(
        _ candidates: [TimeStoryCandidate],
        bounds: (start: Int64, end: Int64)?
    ) -> [ChapterDraft] {
        let ordered = candidates.sorted(by: candidateTimeOrder)
        var result: [ChapterDraft] = []
        var runCounts: [String: Int] = [:]
        for candidate in ordered {
            let baseKey: String
            let title: String
            if let place = candidate.placeName {
                baseKey = "place|\(place)"
                title = place
            } else {
                let stage = stageKey(candidate, bounds: bounds)
                baseKey = "time|\(stage)"
                title = ["早期时光", "成长片段", "最近足迹"][stage]
            }
            if result.last?.key.hasPrefix(baseKey + "|") == true {
                result[result.count - 1].assetIDs.append(candidate.assetID)
            } else {
                let run = runCounts[baseKey, default: 0]
                runCounts[baseKey] = run + 1
                result.append(
                    ChapterDraft(
                        key: "\(baseKey)|\(run)",
                        title: title,
                        assetIDs: [candidate.assetID]
                    )
                )
            }
        }
        return result
    }

    private func candidateTimeOrder(_ lhs: TimeStoryCandidate, _ rhs: TimeStoryCandidate) -> Bool {
        if lhs.mediaCreatedAtMs != rhs.mediaCreatedAtMs {
            switch (lhs.mediaCreatedAtMs, rhs.mediaCreatedAtMs) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        return lhs.assetID.uuidString < rhs.assetID.uuidString
    }
}

enum TimeStoryStableID {
    static func uuid(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        let uuid = bytes.withUnsafeBytes { raw in raw.load(as: uuid_t.self) }
        return UUID(uuid: uuid)
    }
}

struct TimeStoryProjectStore: Sendable {
    let rootDirectory: URL

    init(applicationSupportDirectory: URL) {
        rootDirectory = applicationSupportDirectory
            .appendingPathComponent("Stories", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    func save(_ project: TimeStoryProject) throws {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            let destination = projectURL(project.id)
            let temporary = rootDirectory.appendingPathComponent(".\(project.id.uuidString).\(UUID().uuidString).tmp")
            let data = try JSONEncoder.timeStory.encode(project)
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw TimeStoryError.persistenceFailed
        }
    }

    func load(_ id: UUID) throws -> TimeStoryProject {
        let url = projectURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TimeStoryError.projectNotFound
        }
        do {
            let project = try JSONDecoder.timeStory.decode(TimeStoryProject.self, from: Data(contentsOf: url))
            guard project.schemaVersion == TimeStoryConstants.schemaVersion else {
                throw TimeStoryError.projectCorrupt
            }
            return project
        } catch let error as TimeStoryError {
            throw error
        } catch {
            throw TimeStoryError.projectCorrupt
        }
    }

    func list() throws -> [TimeStoryProjectSummary] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "imageallstory" }
            .compactMap { url -> TimeStoryProjectSummary? in
                guard let data = try? Data(contentsOf: url),
                      let project = try? JSONDecoder.timeStory.decode(TimeStoryProject.self, from: data)
                else { return nil }
                return TimeStoryProjectSummary(
                    id: project.id,
                    subjectTagID: project.subjectTagID,
                    title: project.title,
                    subjectTagDisplayName: project.subjectTagDisplayName,
                    updatedAtMs: project.updatedAtMs,
                    durationSeconds: project.timelineDurationSeconds
                )
            }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        } catch {
            throw TimeStoryError.persistenceFailed
        }
    }

    private func projectURL(_ id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString.lowercased()).imageallstory")
    }
}

protocol TimeStoryMediaValidating: Sendable {
    func validate(_ project: TimeStoryProject) throws -> [TimeStoryMediaValidationIssue]
}

struct TimeStoryMediaValidator: TimeStoryMediaValidating, Sendable {
    let database: CatalogDatabase

    func validate(_ project: TimeStoryProject) throws -> [TimeStoryMediaValidationIssue] {
        guard !project.shots.isEmpty else { return [] }
        let ids = project.shots.map { $0.assetID.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, content_revision, availability, locator_state FROM asset WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
        var current: [UUID: (Int, String, String)] = [:]
        for row in rows {
            let rawID: String = row["id"]
            if let id = UUID(uuidString: rawID) {
                current[id] = (row["content_revision"], row["availability"], row["locator_state"])
            }
        }
        return project.shots.enumerated().compactMap { index, shot in
            guard let fact = current[shot.assetID] else {
                return TimeStoryMediaValidationIssue(
                    shotIndex: index + 1,
                    assetID: shot.assetID,
                    kind: .missing,
                    expectedRevision: shot.contentRevision,
                    actualRevision: nil
                )
            }
            if fact.1 != AssetAvailability.available.rawValue || fact.2 != AssetLocatorState.current.rawValue {
                return TimeStoryMediaValidationIssue(
                    shotIndex: index + 1,
                    assetID: shot.assetID,
                    kind: .unavailable,
                    expectedRevision: shot.contentRevision,
                    actualRevision: fact.0
                )
            }
            if fact.0 != shot.contentRevision {
                return TimeStoryMediaValidationIssue(
                    shotIndex: index + 1,
                    assetID: shot.assetID,
                    kind: .versionChanged,
                    expectedRevision: shot.contentRevision,
                    actualRevision: fact.0
                )
            }
            return nil
        }
    }
}

struct TimeStoryFrozenVideo: Sendable {
    let url: URL
    let contentRevision: Int
    let durationMs: Int64
    let mediaType: String
    let byteCount: Int64
    let sha256: Data
}

protocol TimeStoryMediaLoading: Sendable {
    func loadStoryImage(assetID: UUID) async throws -> Data
    func loadStoryThumbnail(assetID: UUID) async throws -> Data
    func freezeStoryVideo(assetID: UUID, expectedRevision: Int, destination: URL) async throws -> TimeStoryFrozenVideo
}

extension TimeStoryMediaLoading {
    func freezeStoryVideo(assetID: UUID, expectedRevision: Int, destination: URL) async throws -> TimeStoryFrozenVideo {
        throw TimeStoryError.renderingFailed("当前媒体接口不支持视频素材冻结")
    }
    func loadStoryThumbnail(assetID: UUID) async throws -> Data { try await loadStoryImage(assetID: assetID) }
}

extension LibraryAssetImageLoader: TimeStoryMediaLoading {
    func loadStoryThumbnail(assetID: UUID) async throws -> Data {
        try await load(assetID: assetID, variant: .originalAspectThumbnail)
    }
    func loadStoryImage(assetID: UUID) async throws -> Data {
        try await load(assetID: assetID, variant: .preview)
    }
}

struct TimeStoryRenderProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing
        case rendering
        case addingMusic
        case publishing
    }

    let phase: Phase
    let fraction: Double
}

protocol TimeStoryRendering: Sendable {
    func render(
        project: TimeStoryProject,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TimeStoryRenderProgress) -> Void
    ) async throws
}

struct AVFoundationTimeStoryRenderer: TimeStoryRendering, Sendable {
    let media: any TimeStoryMediaLoading
    let temporaryDirectory: URL

    func render(
        project: TimeStoryProject,
        destinationURL: URL,
        onProgress: @escaping @Sendable (TimeStoryRenderProgress) -> Void
    ) async throws {
        guard !project.shots.isEmpty else { throw TimeStoryError.noSelectedShots }
        let timeline = try TimeStoryTimeline.normalize(project: project, allowsVideoClips: true)
        guard destinationURL.pathExtension.lowercased() == "mp4" else {
            throw TimeStoryError.invalidDestination
        }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let workingDirectory = temporaryDirectory
            .appendingPathComponent("time-story-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let silentURL = workingDirectory.appendingPathComponent("silent.mp4")
        let composedURL = workingDirectory.appendingPathComponent("composed.mp4")
        onProgress(TimeStoryRenderProgress(phase: .preparing, fraction: 0))

        var images: [UUID: CGImage] = [:]
        var videos: [UUID: StoryVideoFrames] = [:]
        var videoSources: [UUID: URL] = [:]
        let uniqueAssetIDs = project.shots.reduce(into: [UUID]()) { result, shot in
            if !result.contains(shot.assetID) { result.append(shot.assetID) }
        }
        for (index, assetID) in uniqueAssetIDs.enumerated() {
            try Task.checkCancellation()
            let shots = project.shots.filter { $0.assetID == assetID }
            if shots.contains(where: { $0.videoClip != nil }) {
                guard shots.allSatisfy({ $0.videoClip != nil }), Set(shots.map(\.contentRevision)).count == 1,
                      let revision = shots.first?.contentRevision else {
                    throw TimeStoryError.renderingFailed("同一视频的镜头类型或内容版本不一致")
                }
                let frozen = try await media.freezeStoryVideo(assetID: assetID, expectedRevision: revision,
                    destination: workingDirectory.appendingPathComponent("source-\(assetID.uuidString).mov"))
                guard frozen.contentRevision == revision else { throw TimeStoryError.renderingFailed("视频版本已变化") }
                videoSources[assetID] = frozen.url
                let asset = AVURLAsset(url: frozen.url)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0,
                      duration.seconds < Double(Int64.max / 1000),
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                    throw TimeStoryError.renderingFailed("视频无法解码或没有视频轨")
                }
                let actualMs = Int64((duration.seconds * 1000).rounded(.down))
                for shot in shots {
                    guard let clip = shot.videoClip else { continue }
                    let range = try clip.validatedFrameRange(actualDurationMs: actualMs)
                    videos[shot.id] = StoryVideoFrames(asset: asset, range: range)
                }
                continue
            }
            let data = try await media.loadStoryImage(assetID: assetID)
            guard let image = Self.decodeImage(data) else {
                throw TimeStoryError.renderingFailed("素材 \(index + 1) 无法解码")
            }
            images[assetID] = image
            onProgress(TimeStoryRenderProgress(
                phase: .preparing,
                fraction: Double(index + 1) / Double(uniqueAssetIDs.count)
            ))
        }
        try await renderVideo(
            timeline: timeline,
            typography: project.resolvedTypography,
            images: images,
            videos: videos,
            outputURL: silentURL,
            onProgress: onProgress
        )
        let originalAudioURL = try await addOriginalAudio(videoURL: silentURL,
            outputURL: workingDirectory.appendingPathComponent("original-audio.mp4"),
            project: project, timeline: timeline, sources: videoSources)
        let finalWorkingURL: URL
        if let music = project.music {
            onProgress(TimeStoryRenderProgress(phase: .addingMusic, fraction: 0))
            let resolvedMusicURL = try Self.resolveMusicURL(music)
            let didAccessMusic = resolvedMusicURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessMusic { resolvedMusicURL.stopAccessingSecurityScopedResource() }
            }
            try await addMusic(
                videoURL: originalAudioURL,
                musicURL: resolvedMusicURL,
                outputURL: composedURL,
                volume: music.volume ?? 1
            )
            finalWorkingURL = composedURL
            onProgress(TimeStoryRenderProgress(phase: .addingMusic, fraction: 1))
        } else {
            finalWorkingURL = originalAudioURL
        }
        try Task.checkCancellation()
        onProgress(TimeStoryRenderProgress(phase: .publishing, fraction: 0))
        try publish(finalWorkingURL, to: destinationURL)
        onProgress(TimeStoryRenderProgress(phase: .publishing, fraction: 1))
    }

    private func renderVideo(
        timeline: TimeStoryFrameTimeline,
        typography: StoryTypography,
        images: [UUID: CGImage],
        videos: [UUID: StoryVideoFrames],
        outputURL: URL,
        onProgress: @escaping @Sendable (TimeStoryRenderProgress) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: TimeStoryConstants.outputWidth,
                AVVideoHeightKey: TimeStoryConstants.outputHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: TimeStoryConstants.outputWidth,
                kCVPixelBufferHeightKey as String: TimeStoryConstants.outputHeight,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw TimeStoryError.renderingFailed("无法创建视频轨") }
        writer.add(input)
        guard writer.startWriting() else {
            throw TimeStoryError.renderingFailed(writer.error?.localizedDescription ?? "编码器无法启动")
        }
        writer.startSession(atSourceTime: .zero)
        let frameCount = timeline.totalFrames
        do {
            for frame in 0 ..< frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let state = timeline.state(atFrame: frame) else { throw TimeStoryError.renderingFailed("时间轴为空") }
                var videoImages: [UUID: CGImage] = [:]
                for segment in [state.current, state.next].compactMap({ $0 }) {
                    if let shotID = segment.shotID, let video = videos[shotID] {
                        videoImages[shotID] = try video.image(localFrame: max(0, frame - segment.startFrame))
                    }
                }
                guard let buffer = Self.makePixelBuffer(state: state, images: images, typography: typography, videoImages: videoImages)
                else {
                    throw TimeStoryError.renderingFailed("无法绘制第 \(frame + 1) 帧")
                }
                let time = CMTime(value: CMTimeValue(frame), timescale: TimeStoryConstants.framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw TimeStoryError.renderingFailed(writer.error?.localizedDescription ?? "视频帧写入失败")
                }
                if frame % 10 == 0 || frame == frameCount - 1 {
                    onProgress(TimeStoryRenderProgress(
                        phase: .rendering,
                        fraction: Double(frame + 1) / Double(frameCount)
                    ))
                }
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw TimeStoryError.renderingFailed(writer.error?.localizedDescription ?? "编码未完成")
            }
        } catch {
            writer.cancelWriting()
            throw error
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
            throw TimeStoryError.renderingFailed("无法重新取得配乐文件访问权限")
        }
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(outputSize.width, outputSize.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static let outputSize = CGSize(
        width: TimeStoryConstants.outputWidth,
        height: TimeStoryConstants.outputHeight
    )

    private static func makePixelBuffer(
        state: TimeStoryTimelineState,
        images: [UUID: CGImage],
        typography: StoryTypography,
        videoImages: [UUID: CGImage] = [:]
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            TimeStoryConstants.outputWidth,
            TimeStoryConstants.outputHeight,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: TimeStoryConstants.outputWidth,
                height: TimeStoryConstants.outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: outputSize))
        draw(
            segment: state.current,
            image: state.current.shotID.flatMap { videoImages[$0] } ?? state.current.assetID.flatMap { images[$0] },
            in: context,
            alpha: 1 - state.blend,
            progress: state.progress, typography: typography
        )
        if let next = state.next {
            draw(
                segment: next,
                image: next.shotID.flatMap { videoImages[$0] } ?? next.assetID.flatMap { images[$0] },
                in: context,
                alpha: state.blend,
                progress: 0, typography: typography
            )
        }
        return buffer
    }

    private static func draw(
        segment: TimeStoryFrameSegment,
        image: CGImage?,
        in context: CGContext,
        alpha: Double,
        progress: Double,
        typography: StoryTypography
    ) {
        switch segment.kind {
        case .projectTitle:
            drawTitle(segment.title ?? "", style: .project, in: context, alpha: alpha, typography: typography)
        case .chapterTitle:
            drawTitle(segment.title ?? "", style: .chapter, in: context, alpha: alpha, typography: typography)
        case .photo:
            guard let image else { return }
            draw(image: image, in: context, alpha: alpha, progress: progress, mode: segment.presentationMode)
            drawCaption(segment.caption ?? "", in: context, alpha: alpha, typography: typography)
        }
    }

    private static func draw(image: CGImage, in context: CGContext, alpha: Double, progress: Double,
                             mode: TimeStoryPresentationMode) {
        guard alpha > 0 else { return }
        let canvas = CGRect(origin: .zero, size: outputSize)
        let imageSize = CGSize(width: image.width, height: image.height)
        context.saveGState()
        context.clip(to: canvas)
        context.setAlpha(CGFloat(alpha))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(canvas)
        if mode == .fullFrameWithBackground {
            context.saveGState()
            context.setAlpha(0.32)
            context.draw(image, in: TimeStoryPresentationMode.aspectFill.imageRect(image: imageSize, canvas: outputSize))
            context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
            context.fill(canvas)
            context.restoreGState()
        }
        context.draw(image, in: mode.imageRect(image: imageSize, canvas: outputSize, progress: progress))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private enum TitleStyle { case project, chapter }

    private static func drawTitle(
        _ title: String,
        style: TitleStyle,
        in context: CGContext,
        alpha: Double,
        typography: StoryTypography
    ) {
        guard alpha > 0 else { return }
        let canvas = CGRect(origin: .zero, size: outputSize)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(alpha))
        context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.082, blue: 0.12, alpha: 1).cgColor)
        context.fill(canvas)
        let size = typography.titleSize * (style == .project ? 1 : 0.8)
        let attributed = NSAttributedString(
            string: title,
            attributes: [
                .font: typography.font(size: size),
                .foregroundColor: NSColor.white,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = CGRect(x: 150, y: 280, width: outputSize.width - 300, height: 520)
        let path = CGPath(rect: textRect, transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.47, alpha: 1).cgColor)
        context.fill(CGRect(x: outputSize.width / 2 - 72, y: 235, width: 144, height: 5))
    }

    private static func drawCaption(_ caption: String, in context: CGContext, alpha: Double, typography: StoryTypography) {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(alpha))
        let attributed = NSAttributedString(
            string: caption,
            attributes: [
                .font: typography.font(size: typography.captionSize),
                .foregroundColor: NSColor.white,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        // Only the glyphs cast a soft dark-gray halo; keep the photo unobscured.
        context.setShadow(offset: .zero, blur: 3,
                          color: NSColor(calibratedWhite: 40 / 255, alpha: 0.9).cgColor)
        context.textPosition = CGPoint(x: (outputSize.width - bounds.width) / 2, y: 62)
        CTLineDraw(line, context)
    }

    private func addOriginalAudio(videoURL: URL, outputURL: URL, project: TimeStoryProject,
                                  timeline: TimeStoryFrameTimeline, sources: [UUID: URL]) async throws -> URL {
        guard project.shots.contains(where: { ($0.videoClip?.originalAudioGain ?? 0) > 0 }) else { return videoURL }
        let silent = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        guard let video = try await silent.loadTracks(withMediaType: .video).first,
              let outputVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimeStoryError.renderingFailed("成片视频轨不可用")
        }
        let fullRange = CMTimeRange(start: .zero, duration: CMTime(value: Int64(timeline.totalFrames), timescale: 30))
        try outputVideo.insertTimeRange(fullRange, of: video, at: .zero)
        var parameters: [AVAudioMixInputParameters] = []
        var retainedAssets: [AVAsset] = []
        for shot in project.shots {
            guard let clip = shot.videoClip, clip.originalAudioGain > 0,
                  let url = sources[shot.assetID], let segment = timeline.segments.first(where: { $0.shotID == shot.id }) else { continue }
            try Task.checkCancellation()
            let frames = try clip.validatedFrameRange(actualDurationMs: clip.sourceDurationMs)
            let selected = CMTimeRange(start: CMTime(value: frames.startFrame, timescale: 30),
                                       duration: CMTime(value: frames.frameCount, timescale: 30))
            let sourceAsset = AVURLAsset(url: url)
            retainedAssets.append(sourceAsset)
            for track in try await sourceAsset.loadTracks(withMediaType: .audio) {
                let intersection = CMTimeRangeGetIntersection(try await track.load(.timeRange), otherRange: selected)
                guard intersection.isValid, intersection.duration > .zero else { continue }
                guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw TimeStoryError.renderingFailed("无法创建原声音轨")
                }
                let placement = CMTime(value: Int64(segment.startFrame), timescale: 30) + intersection.start - selected.start
                try output.insertTimeRange(intersection, of: track, at: placement)
                let gain = AVMutableAudioMixInputParameters(track: output)
                gain.setVolume(Float(clip.originalAudioGain), at: .zero)
                parameters.append(gain)
            }
        }
        guard !parameters.isEmpty else { return videoURL }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TimeStoryError.renderingFailed("无法创建原声导出器")
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        exporter.audioMix = mix; exporter.timeRange = fullRange
        try await exporter.export(to: outputURL, as: .mp4)
        withExtendedLifetime(retainedAssets) {}
        try Task.checkCancellation()
        return outputURL
    }

    private func addMusic(videoURL: URL, musicURL: URL, outputURL: URL, volume: Double) async throws {
        guard volume.isFinite, (0...1).contains(volume) else { throw TimeStoryError.renderingFailed("配乐音量无效") }
        let videoAsset = AVURLAsset(url: videoURL)
        let musicAsset = AVURLAsset(url: musicURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await musicAsset.loadTracks(withMediaType: .audio).first
        else {
            throw TimeStoryError.renderingFailed("配乐或视频轨不可用")
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await musicAsset.load(.duration)
        guard audioDuration.isNumeric, audioDuration.seconds > 0 else {
            throw TimeStoryError.renderingFailed("配乐时长无效")
        }
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TimeStoryError.renderingFailed("无法创建配乐合成")
        }
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        for track in try await videoAsset.loadTracks(withMediaType: .audio) {
            guard let retained = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TimeStoryError.renderingFailed("无法保留视频原声")
            }
            let range = CMTimeRangeGetIntersection(try await track.load(.timeRange), otherRange: CMTimeRange(start: .zero, duration: videoDuration))
            if range.duration > .zero { try retained.insertTimeRange(range, of: track, at: range.start) }
        }
        var cursor = CMTime.zero
        while cursor < videoDuration {
            try Task.checkCancellation()
            let remaining = videoDuration - cursor
            let segment = CMTimeMinimum(audioDuration, remaining)
            try compositionAudio.insertTimeRange(
                CMTimeRange(start: .zero, duration: segment),
                of: audioTrack,
                at: cursor
            )
            cursor = cursor + segment
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TimeStoryError.renderingFailed("无法创建配乐导出器")
        }
        let musicParameters = AVMutableAudioMixInputParameters(track: compositionAudio)
        musicParameters.setVolume(Float(volume), at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [musicParameters]
        exporter.audioMix = mix
        try await exporter.export(to: outputURL, as: .mp4)
    }

    private func publish(_ source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw TimeStoryError.invalidDestination
        }
        let staging = directory.appendingPathComponent(".imageall-story-\(UUID().uuidString).tmp.mp4")
        let backupName = ".imageall-story-\(UUID().uuidString).backup.mp4"
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: .usingNewMetadataOnly
                )
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(backupName))
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw TimeStoryError.renderingFailed(error.localizedDescription)
        }
    }
}

struct TimeStoryFeatureRuntime: Sendable {
    let candidates: TimeStoryCandidateProvider
    let planner: TimeStoryPlanner
    let store: TimeStoryProjectStore
    let validator: any TimeStoryMediaValidating
    let renderer: any TimeStoryRendering
    let packageExporter: any TimeStoryPackageExporting
    let openMontageTasks: any OpenMontageStoryTasking
    let creativeRootProvider: any OpenMontageTaskRootProviding
    let media: any TimeStoryMediaLoading
    let clock: any JobClock
}

private extension JSONEncoder {
    static var timeStory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var timeStory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// At most the two currently composited frames are retained by the rendering loop.
private final class StoryVideoFrames {
    let generator: AVAssetImageGenerator
    let range: TimeStoryVideoClip.FrameRange
    init(asset: AVAsset, range: TimeStoryVideoClip.FrameRange) {
        self.range = range
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: TimeStoryConstants.outputWidth, height: TimeStoryConstants.outputHeight)
        // Decode the requested source time; unlimited tolerance can repeat an old keyframe.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }
    func image(localFrame: Int) throws -> CGImage {
        try Task.checkCancellation()
        let sourceFrame = range.startFrame + min(Int64(localFrame), range.frameCount - 1)
        let image = try generator.copyCGImage(at: CMTime(value: sourceFrame, timescale: 30), actualTime: nil)
        try Task.checkCancellation()
        return image
    }
}
