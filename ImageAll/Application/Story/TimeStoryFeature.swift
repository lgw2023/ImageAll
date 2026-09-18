import AppKit
@preconcurrency import AVFoundation
import CoreText
import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

enum TimeStoryConstants {
    static let schemaVersion = 1
    static let templateVersion = "growth-footprints-v1"
    static let strategyVersion = "time-place-balanced-v1"
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
}

struct TimeStoryCandidateSnapshot: Codable, Sendable, Equatable {
    let id: String
    let createdAtMs: Int64
    let tagID: UUID
    let tagDisplayName: String
    let candidates: [TimeStoryCandidate]
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

enum TimeStoryPresentationMode: String, Codable, Sendable, Equatable {
    case fullFrameWithBackground
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

    var timelineDurationSeconds: Double {
        (try? TimeStoryTimeline.normalize(project: self).durationSeconds) ?? 0
    }

    var timelineFrameCount: Int {
        (try? TimeStoryTimeline.normalize(project: self).totalFrames) ?? 0
    }
}

struct TimeStoryProjectSummary: Sendable, Equatable, Identifiable {
    let id: UUID
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
    static func normalize(project: TimeStoryProject) throws -> TimeStoryFrameTimeline {
        guard !project.shots.isEmpty else { throw TimeStoryError.noSelectedShots }
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

        for chapter in project.chapters {
            let chapterTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chapterTitle.isEmpty else {
                throw TimeStoryError.invalidTimeline("章节标题不能为空")
            }
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
            for shotID in chapter.shotIDs {
                guard let shot = project.shots.first(where: { $0.id == shotID }),
                      shot.chapterID == chapter.id
                else {
                    throw TimeStoryError.invalidTimeline("章节包含未知镜头")
                }
                guard shot.durationSeconds.isFinite, shot.durationSeconds > 0 else {
                    throw TimeStoryError.invalidTimeline("镜头时长必须为有限正数")
                }
                let quantized = Int((shot.durationSeconds * Double(TimeStoryConstants.framesPerSecond)).rounded(.toNearestOrAwayFromZero))
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
                transitionInFrames: overlap
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

    func snapshot(tag: TagListItem, nowMs: Int64) throws -> TimeStoryCandidateSnapshot {
        guard tag.state == .active else { throw TimeStoryError.tagUnavailable }
        var cursor: AssetPageCursor?
        var projections: [AssetGridItemProjection] = []
        var observedCursors = Set<String>()
        repeat {
            let page = try query.fetchAssetPage(
                AssetPageRequest(
                    filter: AssetPageFilter(
                        tagDecisionFilters: [
                            TagDecisionFilter(tagID: tag.id, decision: .accepted),
                        ],
                        mediaKinds: [.image]
                    ),
                    sort: .embeddedTimeOldest,
                    cursor: cursor,
                    limit: 500
                )
            )
            projections.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor {
                let marker = String(describing: cursor)
                guard observedCursors.insert(marker).inserted else {
                    throw TimeStoryError.persistenceFailed
                }
            }
        } while cursor != nil

        guard !projections.isEmpty else { throw TimeStoryError.noCandidates }
        let candidates = try metadataCandidates(for: projections)
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
        let digest = SHA256.hash(data: digestPayload).map { String(format: "%02x", $0) }.joined()
        return TimeStoryCandidateSnapshot(
            id: "sha256:\(digest)",
            createdAtMs: nowMs,
            tagID: tag.id,
            tagDisplayName: tag.displayName,
            candidates: canonicalCandidates
        )
    }

    private func metadataCandidates(
        for projections: [AssetGridItemProjection]
    ) throws -> [TimeStoryCandidate] {
        let ids = projections.map(\.assetID)
        var rowsByID: [UUID: Row] = [:]
        for batchStart in stride(from: 0, to: ids.count, by: 400) {
            let batch = Array(ids[batchStart ..< min(ids.count, batchStart + 400)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let arguments = StatementArguments(batch.map { $0.uuidString.lowercased() })
            let rows = try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id,
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
                      ON similarity.asset_id = asset.id AND similarity.media_kind = 'image'
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
        return projections.compactMap { projection in
            guard let metadata = rowsByID[projection.assetID] else { return nil }
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
            return TimeStoryCandidate(
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
        let reliable = allCandidates.filter { $0.mediaCreatedAtMs != nil }
        guard !reliable.isEmpty else { throw TimeStoryError.noReliableTime }
        let selectable = reliable.filter { $0.availability == .available }
        guard !selectable.isEmpty else { throw TimeStoryError.noSelectedShots }

        let excluded = existing?.excludedAssetIDs ?? []
        let candidateByID = Dictionary(uniqueKeysWithValues: allCandidates.map { ($0.assetID, $0) })
        let preservedShots = (existing?.shots ?? []).filter {
            ($0.isLocked || $0.isUserEdited)
                && !excluded.contains($0.assetID)
                && candidateByID[$0.assetID] != nil
        }
        let preservedIDs = Set(preservedShots.map(\.assetID))
        let storyTimeBounds = timeBounds(reliable)
        var selected = selectCandidates(
            selectable.filter { !excluded.contains($0.assetID) && !preservedIDs.contains($0.assetID) },
            limit: max(0, TimeStoryConstants.maximumShots - preservedShots.count)
        )
        selected.append(contentsOf: preservedShots.compactMap { candidateByID[$0.assetID] })
        selected.sort(by: candidateTimeOrder)

        let oldShotByAssetID = Dictionary(uniqueKeysWithValues: (existing?.shots ?? []).map { ($0.assetID, $0) })
        var shots = selected.map { candidate -> TimeStoryShot in
            if var old = oldShotByAssetID[candidate.assetID], old.isLocked || old.isUserEdited {
                old.contentRevision = candidate.contentRevision
                return old
            }
            return TimeStoryShot(
                id: TimeStoryStableID.uuid("shot|\(candidate.assetID.uuidString.lowercased())"),
                assetID: candidate.assetID,
                contentRevision: candidate.contentRevision,
                chapterID: UUID(),
                caption: candidate.placeName ?? snapshot.tagDisplayName,
                durationSeconds: TimeStoryConstants.defaultShotDurationSeconds,
                presentationMode: .fullFrameWithBackground,
                reasons: reasons(for: candidate, among: selected, bounds: storyTimeBounds),
                isLocked: false,
                isUserEdited: false
            )
        }

        let chapterDrafts = makeChapterDrafts(selected, bounds: storyTimeBounds)
        let oldChaptersByID = Dictionary(uniqueKeysWithValues: (existing?.chapters ?? []).map { ($0.id, $0) })
        var chapters: [TimeStoryChapter] = []
        for draft in chapterDrafts {
            let chapterID = TimeStoryStableID.uuid("chapter|\(draft.key)")
            let shotIDs = draft.assetIDs.compactMap { assetID in
                shots.first(where: { $0.assetID == assetID })?.id
            }
            let old = oldChaptersByID[chapterID]
            chapters.append(
                TimeStoryChapter(
                    id: chapterID,
                    title: old?.isUserEdited == true ? old!.title : draft.title,
                    shotIDs: shotIDs,
                    isUserEdited: old?.isUserEdited == true
                )
            )
            for index in shots.indices where shotIDs.contains(shots[index].id) {
                shots[index].chapterID = chapterID
            }
        }

        let namedPlaces = Set(allCandidates.compactMap(\.placeName))
        let similarityReady = allCandidates.contains(where: { $0.similarityState == .ready })
        let omittedReliable = max(0, reliable.count - selected.count)
        let tradeoff: String?
        if omittedReliable > 0 {
            tradeoff = "目标时长内选取 \(selected.count) 张，另有 \(omittedReliable) 张可靠时间素材未进入草稿。"
        } else if allCandidates.count > reliable.count {
            tradeoff = "有 \(allCandidates.count - reliable.count) 张时间未知素材留在待确认区。"
        } else {
            tradeoff = nil
        }
        let readiness = TimeStoryReadinessSummary(
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
            music: existing?.music
        )
    }

    private func selectCandidates(_ candidates: [TimeStoryCandidate], limit: Int) -> [TimeStoryCandidate] {
        guard limit > 0 else { return [] }
        let ordered = candidates.sorted(by: candidateTimeOrder)
        guard ordered.count > limit else { return ordered }
        let bounds = timeBounds(ordered)
        let stages = Dictionary(grouping: ordered) { stageKey($0, bounds: bounds) }
        var selected: [TimeStoryCandidate] = []
        var selectedIDs = Set<UUID>()
        func append(_ candidate: TimeStoryCandidate?) {
            guard let candidate, selected.count < limit, selectedIDs.insert(candidate.assetID).inserted else { return }
            selected.append(candidate)
        }

        for key in [0, 1, 2] {
            append(stages[key]?.max(by: { selectionScore($0) < selectionScore($1) }))
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
        for candidate in ranked where selected.count < limit {
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
            if !isNearDuplicate { append(candidate) }
        }
        for candidate in ordered where selected.count < limit { append(candidate) }
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
        switch stageKey(candidate, bounds: bounds) {
        case 0: result.append("早期代表")
        case 2: result.append("近期代表")
        default: result.append("中期代表")
        }
        if candidate.isFavorite { result.append("收藏照片") }
        if candidate.placeName != nil { result.append("地点变化") }
        if result.count == 1, selected.count > 3 { result.append("阶段多样性") }
        return result
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

protocol TimeStoryMediaLoading: Sendable {
    func loadStoryImage(assetID: UUID) async throws -> Data
}

extension LibraryAssetImageLoader: TimeStoryMediaLoading {
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
        let timeline = try TimeStoryTimeline.normalize(project: project)
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
        let uniqueAssetIDs = project.shots.reduce(into: [UUID]()) { result, shot in
            if !result.contains(shot.assetID) { result.append(shot.assetID) }
        }
        for (index, assetID) in uniqueAssetIDs.enumerated() {
            try Task.checkCancellation()
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
            images: images,
            outputURL: silentURL,
            onProgress: onProgress
        )
        let finalWorkingURL: URL
        if let music = project.music {
            onProgress(TimeStoryRenderProgress(phase: .addingMusic, fraction: 0))
            let resolvedMusicURL = try Self.resolveMusicURL(music)
            let didAccessMusic = resolvedMusicURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessMusic { resolvedMusicURL.stopAccessingSecurityScopedResource() }
            }
            try await addMusic(
                videoURL: silentURL,
                musicURL: resolvedMusicURL,
                outputURL: composedURL
            )
            finalWorkingURL = composedURL
            onProgress(TimeStoryRenderProgress(phase: .addingMusic, fraction: 1))
        } else {
            finalWorkingURL = silentURL
        }
        try Task.checkCancellation()
        onProgress(TimeStoryRenderProgress(phase: .publishing, fraction: 0))
        try publish(finalWorkingURL, to: destinationURL)
        onProgress(TimeStoryRenderProgress(phase: .publishing, fraction: 1))
    }

    private func renderVideo(
        timeline: TimeStoryFrameTimeline,
        images: [UUID: CGImage],
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
                guard let state = timeline.state(atFrame: frame),
                      let buffer = Self.makePixelBuffer(state: state, images: images)
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
        images: [UUID: CGImage]
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
            image: state.current.assetID.flatMap { images[$0] },
            in: context,
            alpha: 1 - state.blend,
            progress: state.progress
        )
        if let next = state.next {
            draw(
                segment: next,
                image: next.assetID.flatMap { images[$0] },
                in: context,
                alpha: state.blend,
                progress: 0
            )
        }
        return buffer
    }

    private static func draw(
        segment: TimeStoryFrameSegment,
        image: CGImage?,
        in context: CGContext,
        alpha: Double,
        progress: Double
    ) {
        switch segment.kind {
        case .projectTitle:
            drawTitle(segment.title ?? "", style: .project, in: context, alpha: alpha)
        case .chapterTitle:
            drawTitle(segment.title ?? "", style: .chapter, in: context, alpha: alpha)
        case .photo:
            guard let image else { return }
            draw(image: image, in: context, alpha: alpha, progress: progress)
            drawCaption(segment.caption ?? "", in: context, alpha: alpha)
        }
    }

    private static func draw(image: CGImage, in context: CGContext, alpha: Double, progress: Double) {
        guard alpha > 0 else { return }
        let canvas = CGRect(origin: .zero, size: outputSize)
        let imageSize = CGSize(width: image.width, height: image.height)
        let fillScale = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let fillSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        let fillRect = CGRect(
            x: (canvas.width - fillSize.width) / 2,
            y: (canvas.height - fillSize.height) / 2,
            width: fillSize.width,
            height: fillSize.height
        )
        context.saveGState()
        context.setAlpha(CGFloat(alpha * 0.32))
        context.draw(image, in: fillRect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        context.fill(canvas)
        context.restoreGState()

        let fitScale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        // A contained foreground moves from slightly smaller to exact fit. It
        // never grows beyond fit, so all four source edges remain visible.
        let subtleScale = fitScale * (0.985 + 0.015 * min(1, max(0, progress)))
        let fitSize = CGSize(width: imageSize.width * subtleScale, height: imageSize.height * subtleScale)
        let fitRect = CGRect(
            x: (canvas.width - fitSize.width) / 2,
            y: (canvas.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
        context.saveGState()
        context.setAlpha(CGFloat(alpha))
        context.draw(image, in: fitRect)
        context.restoreGState()
    }

    private enum TitleStyle { case project, chapter }

    private static func drawTitle(
        _ title: String,
        style: TitleStyle,
        in context: CGContext,
        alpha: Double
    ) {
        guard alpha > 0 else { return }
        let canvas = CGRect(origin: .zero, size: outputSize)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(alpha))
        context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.082, blue: 0.12, alpha: 1).cgColor)
        context.fill(canvas)
        let size: CGFloat = style == .project ? 74 : 58
        let attributed = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont(name: "PingFang SC", size: size)
                    ?? NSFont.systemFont(ofSize: size, weight: .semibold),
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

    private static func drawCaption(_ caption: String, in context: CGContext, alpha: Double) {
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(CGFloat(alpha))
        let attributed = NSAttributedString(
            string: caption,
            attributes: [
                .font: NSFont(name: "PingFang SC", size: 42) ?? NSFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black.withAlphaComponent(0.7),
                .strokeWidth: -3.0,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        let padding: CGFloat = 20
        let background = CGRect(
            x: max(32, (outputSize.width - bounds.width) / 2 - padding),
            y: 52,
            width: min(outputSize.width - 64, bounds.width + padding * 2),
            height: bounds.height + padding
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(background)
        context.textPosition = CGPoint(
            x: (outputSize.width - bounds.width) / 2,
            y: background.minY + padding / 2
        )
        CTLineDraw(line, context)
    }

    private func addMusic(videoURL: URL, musicURL: URL, outputURL: URL) async throws {
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
