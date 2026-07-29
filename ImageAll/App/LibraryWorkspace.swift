import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension MediaKind {
    var displayName: String {
        switch self {
        case .image: "照片"
        case .video: "视频"
        }
    }

    var systemImage: String {
        switch self {
        case .image: "photo.on.rectangle"
        case .video: "play.rectangle"
        }
    }

    var countingNoun: String {
        switch self {
        case .image: "张照片"
        case .video: "个视频"
        }
    }
}

struct MediaKindWorkspaceTabs: View {
    let selection: MediaKind
    let accessibilityIdentifier: String
    let help: String
    let onSelect: (MediaKind) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MediaKind.allCases, id: \.self) { mediaKind in
                Button {
                    onSelect(mediaKind)
                } label: {
                    Label(mediaKind.displayName, systemImage: mediaKind.systemImage)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mediaKind ? Color.accentColor : Color.secondary)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            selection == mediaKind
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                }
                .accessibilityAddTraits(selection == mediaKind ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("媒体类型")
        .accessibilityIdentifier(accessibilityIdentifier)
        .persistentHelp(help)
    }
}

private struct LibraryTagUndoRecord {
    let snapshot: TagMutationPriorStateSnapshot
    let appliedDecision: TagDecisionQueryState
}

private struct ReviewMutationUndoRecord {
    let snapshot: TagMutationPriorStateSnapshot
    let appliedDecision: TagDecisionQueryState
    let tagDisplayName: String
    let affectedCount: Int
}

enum LibraryGridDensity: Int, CaseIterable, Sendable {
    case micro = 0
    case fine = 1
    case compact = 2
    case standard = 3
    case large = 4
    case extraLarge = 5
    case huge = 6
    case massive = 7
    case giant = 8

    static let `default`: Self = .standard

    var displayName: String {
        switch self {
        case .micro: "微缩"
        case .fine: "精细"
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "大图"
        case .extraLarge: "较大"
        case .huge: "很大"
        case .massive: "特大"
        case .giant: "巨大"
        }
    }

    var cellWidthRange: ClosedRange<CGFloat> {
        let bounds = Self.cellWidthBounds[rawValue]
        return bounds.lower ... bounds.upper
    }

    /// Preserves the existing compact / standard / large anchors and extends
    /// downward by 8/11 and upward by 15/11 per step.
    private static let cellWidthBounds: [(lower: CGFloat, upper: CGFloat)] = [
        (51, 84),
        (70, 116),
        (96, 160),
        (132, 220),
        (180, 300),
        (245, 409),
        (334, 558),
        (455, 761),
        (620, 1038),
    ]
}

enum LibraryThumbnailAspectMode: String, CaseIterable, Sendable {
    case square
    case original

    static let `default`: Self = .square

    var displayName: String {
        switch self {
        case .square: "正方形"
        case .original: "原比例"
        }
    }

    var systemImage: String {
        switch self {
        case .square: "square"
        case .original: "aspectratio"
        }
    }

    var toggled: Self {
        switch self {
        case .square: .original
        case .original: .square
        }
    }

    var imageContentMode: ContentMode {
        switch self {
        case .square: .fill
        case .original: .fit
        }
    }

    func frameAspectRatio(
        imageSize: CGSize? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) -> CGFloat {
        guard self == .original else { return 1 }
        if let imageSize,
           imageSize.width.isFinite,
           imageSize.height.isFinite,
           imageSize.width > 0,
           imageSize.height > 0
        {
            return imageSize.width / imageSize.height
        }
        if let pixelWidth,
           let pixelHeight,
           pixelWidth > 0,
           pixelHeight > 0
        {
            return CGFloat(pixelWidth) / CGFloat(pixelHeight)
        }
        return 1
    }
}

struct LibraryGridDensityPicker: View {
    @Binding var selection: LibraryGridDensity
    var help: String
    var displayMode: LibraryToolbarDisplayMode

    init(
        selection: Binding<LibraryGridDensity>,
        help: String = "调整照片网格缩略图大小",
        displayMode: LibraryToolbarDisplayMode = .iconOnly
    ) {
        _selection = selection
        self.help = help
        self.displayMode = displayMode
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(LibraryGridDensity.allCases, id: \.self) { density in
                Text(density.displayName).tag(density)
            }
        } label: {
            switch displayMode {
            case .iconOnly:
                Image(systemName: "square.grid.3x3")
            case .iconAndTitle:
                Label(selection.displayName, systemImage: "square.grid.3x3")
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel("缩略图大小")
        .persistentHelp(help)
    }
}

struct LibraryThumbnailAspectModeButton: View {
    @Binding var selection: LibraryThumbnailAspectMode
    var displayMode: LibraryToolbarDisplayMode

    init(
        selection: Binding<LibraryThumbnailAspectMode>,
        displayMode: LibraryToolbarDisplayMode = .iconOnly
    ) {
        _selection = selection
        self.displayMode = displayMode
    }

    var body: some View {
        Button {
            selection = selection.toggled
        } label: {
            LibraryToolbarLabel(
                title: selection.displayName,
                systemImage: selection.systemImage,
                displayMode: displayMode
            )
        }
        .fixedSize()
        .accessibilityLabel("缩略图比例")
        .accessibilityValue(selection.displayName)
        .persistentHelp(
            selection == .square
                ? "当前缩略图为正方形并填充裁切。点击切换为原比例，完整显示图库、待审核和图库瘦身中的缩略图。"
                : "当前缩略图按图片原比例完整显示。点击切换为正方形并填充裁切；此设置作用于图库、待审核和图库瘦身。"
        )
    }
}

enum TrainingWorkspaceRefreshPresentation {
    case userInitiated
    case automatic
}

enum TrainingWorkspaceActivityScope: Equatable, Sendable {
    case allSources
    case selectedAssets(count: Int)
}

enum TrainingWorkspaceActivityPhase: Equatable, Sendable {
    case preparingSamples
    case preparingEmbeddings(completed: Int, total: Int)
    case trainingAndPublishing
}

struct TrainingWorkspaceActivity: Equatable, Sendable {
    let method: TrainingRunMethod
    let tagNames: [String]
    let scope: TrainingWorkspaceActivityScope
    let sampleCount: Int?
    let phase: TrainingWorkspaceActivityPhase
}

enum LibraryGridNavigationDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

enum LibraryGridPageDirection: Equatable, Sendable {
    case up
    case down
}

enum LibraryBrowsingDestination: Equatable, Sendable {
    case all
    case untagged
    case reviewSuggestions
    case trainingWorkspace
    case librarySlimming
    case source(UUID)
}

enum LibrarySlimmingWorkspaceTab: String, Equatable, Sendable {
    case clusters
    case recycleBin
}

enum LibraryGridLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12
    /// Keep a stable trailing gutter so column/cell math never depends on whether
    /// AppKit has currently materialized a legacy vertical scroller.
    static let verticalScrollerReservedWidth: CGFloat = 16

    static func layoutWidth(containerWidth: CGFloat) -> CGFloat {
        max(containerWidth - verticalScrollerReservedWidth, 0)
    }

    static func columnCount(
        containerWidth: CGFloat,
        density: LibraryGridDensity
    ) -> Int {
        let availableWidth = max(layoutWidth(containerWidth: containerWidth) - horizontalPadding * 2, 0)
        let minimumWidth = density.cellWidthRange.lowerBound
        return max(Int((availableWidth + spacing) / (minimumWidth + spacing)), 1)
    }

    static func cellWidth(
        containerWidth: CGFloat,
        density: LibraryGridDensity
    ) -> CGFloat {
        let columns = columnCount(containerWidth: containerWidth, density: density)
        let availableWidth = max(layoutWidth(containerWidth: containerWidth) - horizontalPadding * 2, 0)
        return max(
            (availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns),
            1
        )
    }

    static func gridItems(
        containerWidth: CGFloat,
        density: LibraryGridDensity
    ) -> [GridItem] {
        let width = cellWidth(containerWidth: containerWidth, density: density)
        return Array(
            repeating: GridItem(.fixed(width), spacing: spacing),
            count: columnCount(containerWidth: containerWidth, density: density)
        )
    }

    static func pageItemCount(
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        density: LibraryGridDensity
    ) -> Int {
        let columns = columnCount(containerWidth: containerWidth, density: density)
        let width = cellWidth(containerWidth: containerWidth, density: density)
        let rows = max(Int((max(containerHeight, 0) + spacing) / (width + spacing)), 1)
        return columns * rows
    }
}

enum LibraryAssetDetailText {
    static func hoverText(_ item: AssetGridItemProjection) -> String {
        var lines = [
            item.fileName ?? "未命名照片",
            "来源：\(item.sourceDisplayName)",
        ]
        if let relativePath = item.relativePath {
            lines.append("位置：\(relativePath)")
        }
        if let width = item.width, let height = item.height {
            lines.append("尺寸：\(formattedInteger(width)) × \(formattedInteger(height))")
        }
        if let durationMs = item.durationMs {
            lines.append("时长：\(VideoDurationText.format(milliseconds: durationMs))")
        }
        lines.append("格式：\(item.mediaType)")
        if let createdAt = item.mediaCreatedAtMs {
            lines.append("拍摄时间：\(formattedDate(milliseconds: createdAt))")
        }
        if let modifiedAt = item.mediaModifiedAtMs {
            lines.append("修改时间：\(formattedDate(milliseconds: modifiedAt))")
        }
        lines.append("标签：已确认 \(item.acceptedTagCount) · 已拒绝 \(item.rejectedTagCount)")
        lines.append("状态：\(availabilityText(item.availability))")
        return lines.joined(separator: "\n")
    }

    static func reviewHoverText(_ item: ReviewQueueItemProjection) -> String {
        [
            item.fileName ?? "未命名照片",
            "建议来源：\(reviewOriginText(item.suggestionOrigin))",
            "标签：已确认 \(item.acceptedTagCount) · 已拒绝 \(item.rejectedTagCount)",
            "状态：\(availabilityText(item.availability))",
        ].joined(separator: "\n")
    }

    static func availabilityText(_ availability: AssetAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .missing: "文件缺失"
        case .unreadable: "不可读取"
        case .unsupported: "格式不支持"
        case .recycled: "回收站"
        }
    }

    private static func formattedInteger(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func formattedDate(milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private static func reviewOriginText(_ origin: ReviewQueueSuggestionOrigin) -> String {
        switch origin {
        case .featurePrint: "特征向量"
        case .standardModel: "标准模型"
        case .personalModel: "个人模型"
        case .personalAdamW: "超级个人"
        }
    }
}

enum LibraryTagSemanticGroup: Int, CaseIterable, Identifiable, Sendable {
    case people
    case placesAndScenes
    case activities
    case food
    case nature
    case documents
    case other

    var id: Int { rawValue }

    var displayName: String { seed.displayName }

    var seed: TagGroupSeed {
        switch self {
        case .people: .people
        case .placesAndScenes: .placesAndScenes
        case .activities: .activities
        case .food: .food
        case .nature: .nature
        case .documents: .documents
        case .other: .other
        }
    }

    static func group(_ tags: [TagListItem]) -> [LibraryTagSemanticSection] {
        let classified = Dictionary(grouping: tags) { TagGroupSeed.classify(displayName: $0.displayName) }
        return TagGroupSeed.allCases.map { seed in
            LibraryTagSemanticSection(
                group: LibraryTagSemanticGroup(rawValue: seed.rawValue) ?? .other,
                tags: (classified[seed] ?? []).sorted { lhs, rhs in
                    let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                    if comparison == .orderedSame {
                        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
                    }
                    return comparison == .orderedAscending
                }
            )
        }
    }
}

struct LibraryTagSemanticSection: Identifiable, Equatable, Sendable {
    let group: LibraryTagSemanticGroup
    let tags: [TagListItem]

    var id: LibraryTagSemanticGroup { group }
}

struct LibraryTagGroupSection: Identifiable, Equatable, Sendable {
    let group: TagGroupListItem
    let tags: [TagListItem]

    var id: UUID { group.id }

    @MainActor
    static func build(
        groups: [TagGroupListItem],
        tags: [TagListItem],
        orderPreferences: LibraryTagOrderPreferences? = nil
    ) -> [LibraryTagGroupSection] {
        let classified = Dictionary(grouping: tags, by: \.groupID)
        return groups.map { group in
            let groupTags = classified[group.id] ?? []
            let orderedTags: [TagListItem]
            if let orderPreferences {
                orderedTags = orderPreferences.ordered(groupTags, in: group.id)
            } else {
                orderedTags = groupTags.sorted(by: Self.alphabetical)
            }
            return LibraryTagGroupSection(group: group, tags: orderedTags)
        }
    }

    private static func alphabetical(_ lhs: TagListItem, _ rhs: TagListItem) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        return comparison == .orderedAscending
    }
}

@MainActor
final class LibraryTagGroupCollapsePreferences {
    private static let defaultKey = "library.sidebar.tag-group-collapse.v1"
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func isCollapsed(_ groupID: UUID) -> Bool {
        collapsedIDs().contains(groupID.uuidString.lowercased())
    }

    func setCollapsed(_ groupID: UUID, collapsed: Bool) {
        var ids = collapsedIDs()
        let token = groupID.uuidString.lowercased()
        if collapsed {
            ids.insert(token)
        } else {
            ids.remove(token)
        }
        defaults.set(Array(ids).sorted(), forKey: key)
    }

    func toggle(_ groupID: UUID) {
        setCollapsed(groupID, collapsed: !isCollapsed(groupID))
    }

    private func collapsedIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}

@MainActor
final class LibrarySourceOrderPreferences {
    private static let defaultKey = "library.sidebar.source-order.v1"
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func ordered(_ sources: [LibrarySourceSummary]) -> [LibrarySourceSummary] {
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let savedIDs = loadIDs()
        let orderedKnown = savedIDs.compactMap { byID[$0] }
        let savedSet = Set(savedIDs)
        let appended = sources.filter { !savedSet.contains($0.id) }
        return orderedKnown + appended
    }

    func move(
        sourceID: UUID,
        before targetID: UUID?,
        in sources: [LibrarySourceSummary]
    ) {
        var ids = ordered(sources).map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sourceID) else { return }
        ids.remove(at: sourceIndex)
        if let targetID, let targetIndex = ids.firstIndex(of: targetID) {
            ids.insert(sourceID, at: targetIndex)
        } else {
            ids.append(sourceID)
        }
        defaults.set(ids.map(\.uuidString), forKey: key)
    }

    func move(
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int,
        in sources: [LibrarySourceSummary]
    ) {
        var ids = ordered(sources).map(\.id)
        let validOffsets = sourceOffsets.filter { ids.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }
        let movedIDs = validOffsets.map { ids[$0] }
        for offset in validOffsets.reversed() {
            ids.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            ids.endIndex
        )
        ids.insert(contentsOf: movedIDs, at: insertionIndex)
        defaults.set(ids.map(\.uuidString), forKey: key)
    }

    private func loadIDs() -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }
}

@MainActor
final class LibraryTagOrderPreferences {
    private static let defaultKey = "library.sidebar.tag-order.v1"
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func ordered(_ tags: [TagListItem], in groupID: UUID) -> [TagListItem] {
        let byID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        let savedIDs = loadIDs(for: groupID)
        let orderedKnown = savedIDs.compactMap { byID[$0] }
        let savedSet = Set(savedIDs)
        let appended = tags
            .filter { !savedSet.contains($0.id) }
            .sorted(by: Self.alphabetical)
        return orderedKnown + appended
    }

    func move(
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int,
        tags: [TagListItem],
        in groupID: UUID
    ) {
        var ids = ordered(tags, in: groupID).map(\.id)
        let validOffsets = sourceOffsets.filter { ids.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }
        let movedIDs = validOffsets.map { ids[$0] }
        for offset in validOffsets.reversed() {
            ids.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            ids.endIndex
        )
        ids.insert(contentsOf: movedIDs, at: insertionIndex)
        saveIDs(ids, for: groupID)
    }

    func remove(_ tagID: UUID, from groupID: UUID) {
        var storage = loadStorage()
        let groupToken = groupID.uuidString.lowercased()
        let tagToken = tagID.uuidString.lowercased()
        guard var ids = storage[groupToken] else { return }
        ids.removeAll { $0 == tagToken }
        storage[groupToken] = ids
        saveStorage(storage)
    }

    func append(_ tagID: UUID, to groupID: UUID, tags: [TagListItem]) {
        var ids = ordered(tags, in: groupID).map(\.id)
        ids.removeAll { $0 == tagID }
        ids.append(tagID)
        saveIDs(ids, for: groupID)
    }

    private static func alphabetical(_ lhs: TagListItem, _ rhs: TagListItem) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        return comparison == .orderedAscending
    }

    private func loadIDs(for groupID: UUID) -> [UUID] {
        let token = groupID.uuidString.lowercased()
        return (loadStorage()[token] ?? []).compactMap(UUID.init(uuidString:))
    }

    private func saveIDs(_ ids: [UUID], for groupID: UUID) {
        var storage = loadStorage()
        storage[groupID.uuidString.lowercased()] = ids.map(\.uuidString)
        saveStorage(storage)
    }

    private func loadStorage() -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    private func saveStorage(_ storage: [String: [String]]) {
        defaults.set(storage, forKey: key)
    }
}

struct LibrarySourceReorderMove: Equatable, Sendable {
    let sourceOffset: Int
    let destinationOffset: Int
}

enum LibrarySourceReorderLayout {
    static func destinationOffset(pointerY: CGFloat, rowFrames: [CGRect]) -> Int {
        let framesTopToBottom = rowFrames.sorted { $0.minY < $1.minY }
        return framesTopToBottom.firstIndex { pointerY < $0.midY } ?? framesTopToBottom.count
    }

    static func moveRequest(
        sourceID: UUID,
        localPointerY: CGFloat,
        sourceIDs: [UUID],
        rowFrames: [CGRect]
    ) -> LibrarySourceReorderMove? {
        guard rowFrames.count == sourceIDs.count,
              let sourceOffset = sourceIDs.firstIndex(of: sourceID)
        else { return nil }
        let framesTopToBottom = rowFrames.sorted { $0.minY < $1.minY }
        let pointerY = framesTopToBottom[sourceOffset].minY + localPointerY
        let destinationOffset = destinationOffset(
            pointerY: pointerY,
            rowFrames: framesTopToBottom
        )
        guard destinationOffset != sourceOffset,
              destinationOffset != sourceOffset + 1
        else { return nil }
        return LibrarySourceReorderMove(
            sourceOffset: sourceOffset,
            destinationOffset: destinationOffset
        )
    }
}

enum LibraryTagReorderLayout {
    static let rowThreshold: CGFloat = 8

    static func readingOrder(tagIDs: [UUID], frames: [UUID: CGRect]) -> [UUID] {
        tagIDs
            .compactMap { id -> (UUID, CGRect)? in
                guard let frame = frames[id] else { return nil }
                return (id, frame)
            }
            .sorted { lhs, rhs in
                if abs(lhs.1.midY - rhs.1.midY) > rowThreshold {
                    return lhs.1.midY < rhs.1.midY
                }
                return lhs.1.midX < rhs.1.midX
            }
            .map(\.0)
    }

    static func destinationOffset(
        pointer: CGPoint,
        tagIDs: [UUID],
        frames: [UUID: CGRect]
    ) -> Int {
        let ordered = readingOrder(tagIDs: tagIDs, frames: frames)
        guard !ordered.isEmpty else { return 0 }

        var bestArrayIndex = tagIDs.count
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for insertionIndex in 0...ordered.count {
            let anchor = insertionAnchor(
                at: insertionIndex,
                ordered: ordered,
                frames: frames
            )
            let distance = hypot(pointer.x - anchor.x, pointer.y - anchor.y)
            if distance < bestDistance {
                bestDistance = distance
                bestArrayIndex = insertionArrayIndex(
                    at: insertionIndex,
                    ordered: ordered,
                    tagIDs: tagIDs
                )
            }
        }
        return bestArrayIndex
    }

    static func moveRequest(
        tagID: UUID,
        pointer: CGPoint,
        tagIDs: [UUID],
        frames: [UUID: CGRect]
    ) -> LibrarySourceReorderMove? {
        guard let sourceOffset = tagIDs.firstIndex(of: tagID) else { return nil }
        let destinationOffset = destinationOffset(
            pointer: pointer,
            tagIDs: tagIDs,
            frames: frames
        )
        guard destinationOffset != sourceOffset,
              destinationOffset != sourceOffset + 1
        else { return nil }
        return LibrarySourceReorderMove(
            sourceOffset: sourceOffset,
            destinationOffset: destinationOffset
        )
    }

    static func targetGroupID(
        pointer: CGPoint,
        groupFrames: [UUID: CGRect]
    ) -> UUID? {
        groupFrames.first { _, frame in frame.contains(pointer) }?.key
    }

    private static func insertionArrayIndex(
        at insertionIndex: Int,
        ordered: [UUID],
        tagIDs: [UUID]
    ) -> Int {
        if insertionIndex >= ordered.count {
            return tagIDs.count
        }
        let id = ordered[insertionIndex]
        return tagIDs.firstIndex(of: id) ?? tagIDs.count
    }

    private static func insertionAnchor(
        at insertionIndex: Int,
        ordered: [UUID],
        frames: [UUID: CGRect]
    ) -> CGPoint {
        if insertionIndex == 0,
           let firstID = ordered.first,
           let frame = frames[firstID]
        {
            return CGPoint(x: frame.minX - 3, y: frame.midY)
        }
        if insertionIndex >= ordered.count,
           let lastID = ordered.last,
           let frame = frames[lastID]
        {
            return CGPoint(x: frame.maxX + 3, y: frame.midY)
        }
        let beforeID = ordered[insertionIndex - 1]
        let afterID = ordered[insertionIndex]
        guard let before = frames[beforeID], let after = frames[afterID] else {
            return .zero
        }
        if abs(before.midY - after.midY) <= rowThreshold {
            return CGPoint(
                x: (before.maxX + after.minX) / 2,
                y: (before.midY + after.midY) / 2
            )
        }
        return CGPoint(x: after.minX - 3, y: after.midY)
    }
}

struct LibraryWorkspaceLayoutState: Equatable {
    static let inspectorCollapseWidth: CGFloat = 840

    private(set) var isSidebarPresented = true
    private(set) var isInspectorPresented = true
    private var hasAppliedNarrowInspectorCollapse = false

    mutating func updateWindowWidth(_ width: CGFloat) {
        if width >= Self.inspectorCollapseWidth {
            hasAppliedNarrowInspectorCollapse = false
        } else if !hasAppliedNarrowInspectorCollapse {
            isInspectorPresented = false
            hasAppliedNarrowInspectorCollapse = true
        }
    }

    mutating func toggleSidebar() {
        setSidebarPresented(!isSidebarPresented)
    }

    mutating func toggleInspector() {
        setInspectorPresented(!isInspectorPresented)
    }

    mutating func setSidebarPresented(_ isPresented: Bool) {
        isSidebarPresented = isPresented
    }

    mutating func setInspectorPresented(_ isPresented: Bool) {
        isInspectorPresented = isPresented
    }
}

enum LibraryWorkspaceCommand: Hashable {
    case showAllPhotos
    case showReviewSuggestions
    case showActivity
    case toggleSidebar
    case toggleInspector
    case showSource(UUID)
    case showTag(UUID)
    case acceptTag(UUID)
    case rejectTag(UUID)
    case clearTagDecision(UUID)
    case createTag
    case connectFolder
    case rescanCurrentSource
    case toggleSinglePhoto
    case showKeyboardShortcuts
}

struct LibraryWorkspaceCommandItem: Identifiable, Equatable {
    let command: LibraryWorkspaceCommand
    let title: String
    let systemImage: String
    let isEnabled: Bool

    var id: LibraryWorkspaceCommand { command }
}

/// Limits concurrent grid thumbnail loads so sidebar navigation and inspector
/// fetches stay responsive while a catalog scan keeps cells visible.
private actor LibraryThumbnailLoadGate {
    private var available: Int
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    init(limit: Int) {
        precondition(limit > 0)
        available = limit
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        // Check before taking a slot. After a waiter is resumed it already owns
        // the permit; throwing here would leak it because withPermit has not
        // installed its defer-release yet.
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            available += 1
        }
    }
}

enum AssetThumbnailLoadResult: Equatable, Sendable {
    case loaded(Data)
    case cloudOnly
    /// Definitive failure for the current catalog facts (authorization, missing asset, etc.).
    case unavailable
    /// Task or waiter was cancelled; caller must not settle the cell as permanently blank.
    case cancelled
    /// Transient decode/I/O/PhotoKit failure that should be retried while the cell stays visible.
    case failed
}

struct LibrarySlimmingIdenticalCleanupExecutionProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case validatingPlan
        case recyclingAssets
        case requestingAuthorization
        case refreshingState
        case verifyingResult
    }

    let phase: Phase
    let completedAssetCount: Int
    let totalAssetCount: Int
}

@MainActor
final class LibraryWorkspaceModel: ObservableObject {
    @Published private(set) var phase: LibraryWorkspacePhase = .loading
    @Published private(set) var sources: [LibrarySourceSummary] = []
    @Published private(set) var items: [AssetGridItemProjection] = []
    @Published private(set) var selectedAssetIDs: Set<UUID> = []
    @Published private(set) var isSinglePhotoPresented = false
    @Published private(set) var inspectorDetail: AssetInspectorDetail?
    @Published private(set) var inspectorTags: [LibraryInspectorTagPresentation] = []
    @Published private(set) var tags: [TagListItem] = []
    @Published private(set) var tagGroups: [TagGroupListItem] = []
    @Published private(set) var tagGroupCollapseRevision = 0
    @Published private(set) var searchText = ""
    @Published private(set) var selectedTagFilterIDs: Set<UUID> = []
    @Published private(set) var excludedTagFilterIDs: Set<UUID> = []
    @Published private(set) var tagMatchMode: TagMatchMode = .all
    @Published private(set) var tagPresence: TagPresenceFilter = .any
    @Published private(set) var selectedAvailabilities: [AssetAvailability] = []
    @Published private(set) var selectedMediaKind: MediaKind = .image
    @Published private(set) var selectedMediaTypes: [String] = []
    @Published private(set) var sort: AssetPageSort = .newest
    @Published private(set) var gridDensity: LibraryGridDensity = .default
    @Published private(set) var thumbnailAspectMode: LibraryThumbnailAspectMode = .default
    @Published private(set) var notice: LibraryWorkspaceNotice?
    @Published private(set) var pendingSuggestionTotal = 0
    @Published private(set) var isCatalogScanning = false
    @Published private(set) var catalogReconcileProgress: CatalogReconcileProgress?
    @Published private(set) var assetGridRevision = 0
    @Published private(set) var suggestionOverviews: [SuggestionTagOverview] = []
    @Published private(set) var reviewMode: ReviewWorkspaceMode?
    @Published private(set) var reviewQueueItems: [ReviewQueueItemProjection] = []
    @Published private(set) var selectedReviewItemID: ReviewQueueItemID?
    @Published fileprivate(set) var reviewNextCursor: ReviewQueueCursor?
    /// `nil` = all active sources; otherwise only the selected subset (may be empty).
    @Published private(set) var reviewFilterSourceIDs: Set<UUID>?
    @Published var pendingSuggestionConfirmation: SuggestionEnqueueConfirmation?
    @Published private(set) var assetPendingSuggestions: [AssetPendingSuggestion] = []
    @Published private(set) var cloudPreviewState: CloudPreviewPresentationState = .hidden
    @Published private(set) var localModelSuggestionState: LocalModelSuggestionPresentationState = .hidden
    @Published private(set) var localModelServiceHealthState: LocalModelServiceHealthPresentationState = .unchecked
    @Published private(set) var localModelSuggestionTrack: ModelSuggestionTrack = .standard
    @Published private(set) var personalLibrarySuggestionState: PersonalLibrarySuggestionPresentationState = .idle
    @Published private(set) var personalLibrarySuggestionJobID: UUID?
    @Published private(set) var standardLibrarySuggestionState: StandardLibrarySuggestionPresentationState = .idle
    @Published private(set) var standardLibrarySuggestionJobID: UUID?
    @Published private(set) var isRebuildingPersonalModel = false
    @Published private(set) var isRebuildingPersonalAdamWModel = false
    @Published private(set) var isCachingSelectedAssetEmbedding = false
    @Published private(set) var isGeneratingAppPersonalSampleSuggestions = false
    @Published private(set) var appPersonalSampleSuggestionProgress:
        (checked: Int, suggested: Int, skipped: Int, total: Int)?
    @Published private(set) var isGeneratingAppPersonalTagLibrarySuggestions = false
    @Published private(set) var appPersonalTagLibrarySuggestionProgress:
        (checked: Int, suggested: Int, skipped: Int, total: Int)?
    @Published private(set) var isExportingPortableData = false
    @Published private(set) var previewCacheUsage = DerivedImageCacheUsage.zero
    @Published private(set) var photosOriginalStorageUsage = PhotosOriginalStorageUsage.zero
    @Published private(set) var appStorageLocation: AppStorageLocationStatus?
    @Published private(set) var isClearingPreviewCache = false
    @Published private(set) var isClearingPhotosOriginalStorage = false
    @Published private(set) var isChoosingAppStorageLocation = false
    @Published private(set) var isIdleThumbnailPrewarmEnabled: Bool
    @Published private(set) var maxPendingSuggestionsPerTag: Int
    /// Bumped when suggestion thresholds change so SwiftUI re-reads effective values.
    @Published private(set) var suggestionThresholdEpoch = 0
    @Published private(set) var sourceThumbnailPrewarmProgress: SourceThumbnailPrewarmProgress?
    @Published private(set) var jobActivityItems: [JobActivityItem] = []
    @Published private(set) var jobActivityActionInFlightIDs: Set<UUID> = []
    @Published private(set) var sourceOrderRevision = 0
    @Published private(set) var tagOrderRevision = 0
    @Published private(set) var isOpeningOriginal = false
    @Published private(set) var trainingRuns: [TrainingRunRecord] = []
    @Published private(set) var trainingSlots: [TrainingWorkspaceSlot] =
        TrainingRunMethod.allCases.map {
            TrainingWorkspaceSlot(
                method: $0,
                isPublished: false,
                publishedRunID: nil,
                artifactRef: nil
            )
        }
    @Published private(set) var trainingRunMethodFilter: TrainingRunMethod?
    @Published private(set) var selectedTrainingRunID: UUID?
    @Published private(set) var isRefreshingTrainingWorkspace = false
    @Published private(set) var trainingWorkspaceActivity: TrainingWorkspaceActivity?
    @Published private(set) var librarySlimmingClusters: [LibrarySlimmingClusterPresentation] = []
    @Published private(set) var librarySlimmingAnalysisJobs: [LibrarySlimmingAnalysisJobPresentation] = []
    @Published private(set) var selectedLibrarySlimmingClusterID: UUID?
    @Published private(set) var librarySlimmingPendingCount = 0
    @Published private(set) var isAnalyzingLibrarySlimming = false
    @Published private(set) var librarySlimmingStatusMessage: String?
    @Published private(set) var librarySlimmingRecycleActionMessage: String?
    @Published private(set) var librarySlimmingScanProgress: LibrarySlimmingScanProgress?
    @Published private(set) var librarySlimmingAnalyzeMode: LibrarySlimmingAnalyzeMode = .catalog
    /// `nil` means every active source; an empty set intentionally means no source.
    @Published private(set) var librarySlimmingCatalogSourceIDs: Set<UUID>?
    @Published private(set) var librarySlimmingAnalysisJobID: UUID?
    @Published private(set) var librarySlimmingAnalysisJobState: JobState?
    @Published private(set) var librarySlimmingAnalysisControlRequest: JobControlRequest = .none
    @Published private(set) var librarySlimmingSeedAssetIDs: [UUID] = []
    @Published private(set) var selectedLibrarySlimmingMemberIDs: Set<UUID> = []
    @Published private(set) var hasCompletedLibrarySlimmingScan = false
    @Published private(set) var librarySlimmingWorkspaceTab: LibrarySlimmingWorkspaceTab = .clusters
    @Published private(set) var librarySlimmingRecycleEntries: [RecycleEntryRecord] = []
    @Published private var librarySlimmingThumbnailReloadVersions: [UUID: Int] = [:]
    @Published private(set) var librarySlimmingMemberSourceNames: [UUID: String] = [:]
    @Published private(set) var librarySlimmingSceneThresholds = NearDuplicateSceneThresholds.factory
    @Published private(set) var sourceSimilarityIndexStatus: SourceSimilarityIndexStatus?
    @Published private(set) var isInitializingSourceSimilarityIndex = false
    @Published var showsLibrarySlimmingThresholdEditor = false
    @Published private(set) var isMutatingLibrarySlimmingRecycle = false
    @Published private(set) var isPreparingLibrarySlimmingIdenticalCleanup = false
    @Published private(set) var librarySlimmingIdenticalCleanupExecutionProgress:
        LibrarySlimmingIdenticalCleanupExecutionProgress?
    @Published private(set) var librarySlimmingIdenticalCleanupPostDeleteReport:
        LibrarySlimmingIdenticalCleanupPostDeleteReport?
    /// Bumped when toolbar asks the sidebar view to switch into 图库瘦身.
    @Published private(set) var librarySlimmingNavigationNonce = UUID()
    private var shouldAutoAnalyzeLibrarySlimmingSeeds = false
    private var librarySlimmingSeedAnalyzeNavigationRequestID: UUID?

    fileprivate let review: any PersonalizationReviewPort
    private let service: any LibraryWorkspacePort
    private let trainingWorkspace: (any TrainingWorkspacePort)?
    private let librarySlimming: (any LibrarySlimmingScanPort)?
    private let librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)?
    private let librarySlimmingSourceIndex: (any SourceSimilarityIndexPort)?
    private let librarySlimmingRecycle: (any LibrarySlimmingRecyclePort)?
    private let librarySlimmingRecycleConfirmationPreferences:
        any LibrarySlimmingRecycleConfirmationPreferenceStore
    private let librarySlimmingThresholds: (any NearDuplicateSceneThresholdWriting)?
    private let librarySlimmingMutationAuthorization: (any FolderMutationAuthorizationPort)?
    private let photosLibraryMutation: (any PhotosLibraryMutationPort)?
    private let localModelSuggestions: LocalModelSuggestionRuntime?
    private let appPersonalModelRebuilder: (any AppPersonalModelRebuilding)?
    private let appPersonalAdamWModelRebuilder: (any AppPersonalModelRebuilding)?
    private let selectedAssetEmbeddingCache: (any AppSelectedAssetEmbeddingCaching)?
    private let idleFeaturePrintCache: (any SyncFeatureVectorLoading)?
    private let appPersonalSampleSuggester: (any AppPersonalSampleSuggesting)?
    private let appPersonalTagLibrarySuggester: (any AppPersonalTagLibrarySuggesting)?
    private let appPersonalAdamWTagLibrarySuggester: (any AppPersonalTagLibrarySuggesting)?
    private let suggestionThresholds: (any SuggestionThresholdPort)?
    private let originalAssetOpener: any LibraryOriginalAssetOpening
    private let sourceOrderPreferences: LibrarySourceOrderPreferences
    private let tagOrderPreferences: LibraryTagOrderPreferences
    private let tagGroupCollapsePreferences: LibraryTagGroupCollapsePreferences
    private let clock: any JobClock
    private var lastTagMutation: LibraryTagUndoRecord?
    fileprivate var lastReviewMutation: ReviewMutationUndoRecord?
    private var personalizationRunnerTask: Task<Void, Never>?
    private var librarySlimmingAnalysisRunnerTask: Task<Void, Never>?
    private var librarySlimmingAnalysisProgressMonitorTask: Task<Void, Never>?
    private var librarySlimmingSourceLoadTask: Task<Void, Never>?
    private var sourceSimilarityIndexRunnerTask: Task<Void, Never>?
    private var catalogReconcileTask: Task<Void, Never>?
    private var catalogReconcileRunRequested = false
    private var isLibrarySlimmingWorkspaceActive = false
    private var librarySlimmingCatalogRefreshPendingAfterExit = false
    private var librarySlimmingCatalogRefreshSourceIDs: Set<UUID> = []
    private var reportsLibrarySlimmingCatalogRefreshCompletion = false
    private var librarySlimmingIdenticalCleanupExecutionID: UUID?
    private var cloudPreviewTask: Task<Void, Never>?
    private var cloudPreviewRequestID: UUID?
    private var localModelSuggestionRequestID: UUID?
    private var searchDebounceTask: Task<Void, Never>?
    private var assetPageRequestID: UUID?
    private var reviewPageRequestID: UUID?
    private var hiddenRecycledAssetIDs: Set<UUID> = []
    private var thumbnailDataCache: [UUID: Data] = [:]
    private var thumbnailCacheVersions: [UUID: Int] = [:]
    private var thumbnailCacheOrder: [UUID] = []
    private let thumbnailCacheCapacity = 3_000
    private let thumbnailLoadGate: LibraryThumbnailLoadGate
    private var thumbnailLoadEpoch = 0
    private let idleThumbnailPrewarmPreferenceStore: any IdleThumbnailPrewarmPreferenceStore
    private let pendingSuggestionCountPreferences: any PendingSuggestionCountPreferenceStore
    private let idlePrewarmClock: any IdlePrewarmClock
    private let idlePrewarmThresholdSeconds: TimeInterval
    private let idlePrewarmMonitorTickSeconds: TimeInterval
    private let idlePrewarmInstallEventMonitor: Bool
    private var idleThumbnailPrewarmController: IdleThumbnailPrewarmController?
    private var idlePrewarmSkippedAssetIDs: Set<UUID> = []
    private var idlePrewarmEmbeddingUnavailable = false
    private var sourceThumbnailPrewarmTask: Task<Void, Never>?
    private var sourceThumbnailPrewarmGeneration = 0
    private var browsingNavigationRequestID: UUID?
    private var selectionAnchorID: UUID?
    private var librarySlimmingSelectionAnchorID: UUID?
    private struct FeatureSuggestionCompletionContext: Equatable {
        let tagID: UUID
        let displayName: String
    }

    private var featureSuggestionCompletionContexts: [UUID: FeatureSuggestionCompletionContext] = [:]
    private var isTrainingWorkspaceRefreshInFlight = false
    private var selectedTagFilterDecisions: [UUID: PersistableTagDecision] = [:]
    private var selectedSourceID: UUID?
    private var nextCursor: AssetPageCursor?
    private var started = false
    private var isLibrarySlimmingMaintenanceRunning = false
    private var isLoadingMore = false
    fileprivate var isLoadingMoreReviewQueue = false
    private let catalogProgressRefreshInterval: Duration
    private let searchDebounceInterval: Duration

    init(
        service: any LibraryWorkspacePort,
        review: any PersonalizationReviewPort = EmptyPersonalizationReviewPort(),
        trainingWorkspace: (any TrainingWorkspacePort)? = nil,
        librarySlimming: (any LibrarySlimmingScanPort)? = nil,
        librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)? = nil,
        librarySlimmingSourceIndex: (any SourceSimilarityIndexPort)? = nil,
        librarySlimmingRecycle: (any LibrarySlimmingRecyclePort)? = nil,
        librarySlimmingRecycleConfirmationPreferences:
            any LibrarySlimmingRecycleConfirmationPreferenceStore =
            UserDefaultsLibrarySlimmingRecycleConfirmationPreferenceStore(),
        librarySlimmingMutationAuthorization: (any FolderMutationAuthorizationPort)? = nil,
        photosLibraryMutation: (any PhotosLibraryMutationPort)? = nil,
        librarySlimmingThresholds: (any NearDuplicateSceneThresholdWriting)? = nil,
        localModelSuggestions: LocalModelSuggestionRuntime? = nil,
        appPersonalModelRebuilder: (any AppPersonalModelRebuilding)? = nil,
        appPersonalAdamWModelRebuilder: (any AppPersonalModelRebuilding)? = nil,
        selectedAssetEmbeddingCache: (any AppSelectedAssetEmbeddingCaching)? = nil,
        idleFeaturePrintCache: (any SyncFeatureVectorLoading)? = nil,
        appPersonalSampleSuggester: (any AppPersonalSampleSuggesting)? = nil,
        appPersonalTagLibrarySuggester: (any AppPersonalTagLibrarySuggesting)? = nil,
        appPersonalAdamWTagLibrarySuggester: (any AppPersonalTagLibrarySuggesting)? = nil,
        suggestionThresholds: (any SuggestionThresholdPort)? = nil,
        pendingSuggestionCountPreferences: any PendingSuggestionCountPreferenceStore =
            UserDefaultsPendingSuggestionCountPreferenceStore(),
        originalAssetOpener: any LibraryOriginalAssetOpening = UnavailableLibraryOriginalAssetOpener(),
        sourceOrderPreferences: LibrarySourceOrderPreferences = LibrarySourceOrderPreferences(),
        tagOrderPreferences: LibraryTagOrderPreferences = LibraryTagOrderPreferences(),
        tagGroupCollapsePreferences: LibraryTagGroupCollapsePreferences = LibraryTagGroupCollapsePreferences(),
        clock: any JobClock = SystemJobClock(),
        catalogProgressRefreshInterval: Duration = .milliseconds(750),
        searchDebounceInterval: Duration = .milliseconds(300),
        thumbnailLoadConcurrencyLimit: Int = 4,
        idleThumbnailPrewarmPreferenceStore: any IdleThumbnailPrewarmPreferenceStore =
            UserDefaultsIdleThumbnailPrewarmPreferenceStore(),
        idlePrewarmClock: any IdlePrewarmClock = SystemIdlePrewarmClock(),
        idlePrewarmThresholdSeconds: TimeInterval = IdleThumbnailPrewarmDefaults.idleThresholdSeconds,
        idlePrewarmMonitorTickSeconds: TimeInterval = IdleThumbnailPrewarmDefaults.monitorTickSeconds,
        idlePrewarmInstallEventMonitor: Bool = true
    ) {
        self.service = service
        self.review = review
        self.trainingWorkspace = trainingWorkspace
        self.librarySlimming = librarySlimming
        self.librarySlimmingAnalysis = librarySlimmingAnalysis
        self.librarySlimmingSourceIndex = librarySlimmingSourceIndex
        self.librarySlimmingRecycle = librarySlimmingRecycle
        self.librarySlimmingRecycleConfirmationPreferences =
            librarySlimmingRecycleConfirmationPreferences
        self.librarySlimmingMutationAuthorization = librarySlimmingMutationAuthorization
        self.photosLibraryMutation = photosLibraryMutation
        self.librarySlimmingThresholds = librarySlimmingThresholds
        librarySlimmingSceneThresholds = librarySlimmingThresholds?.thresholds() ?? .factory
        self.localModelSuggestions = localModelSuggestions
        self.appPersonalModelRebuilder = appPersonalModelRebuilder
        self.appPersonalAdamWModelRebuilder = appPersonalAdamWModelRebuilder
        self.idleThumbnailPrewarmPreferenceStore = idleThumbnailPrewarmPreferenceStore
        self.idlePrewarmClock = idlePrewarmClock
        self.idlePrewarmThresholdSeconds = idlePrewarmThresholdSeconds
        self.idlePrewarmMonitorTickSeconds = idlePrewarmMonitorTickSeconds
        self.idlePrewarmInstallEventMonitor = idlePrewarmInstallEventMonitor
        isIdleThumbnailPrewarmEnabled = idleThumbnailPrewarmPreferenceStore.isEnabled
        maxPendingSuggestionsPerTag = pendingSuggestionCountPreferences.maxPendingSuggestionsPerTag
        self.selectedAssetEmbeddingCache = selectedAssetEmbeddingCache
        self.idleFeaturePrintCache = idleFeaturePrintCache
        self.appPersonalSampleSuggester = appPersonalSampleSuggester
        self.appPersonalTagLibrarySuggester = appPersonalTagLibrarySuggester
        self.appPersonalAdamWTagLibrarySuggester = appPersonalAdamWTagLibrarySuggester
        self.suggestionThresholds = suggestionThresholds
        self.pendingSuggestionCountPreferences = pendingSuggestionCountPreferences
        self.originalAssetOpener = originalAssetOpener
        self.sourceOrderPreferences = sourceOrderPreferences
        self.tagOrderPreferences = tagOrderPreferences
        self.tagGroupCollapsePreferences = tagGroupCollapsePreferences
        self.clock = clock
        self.catalogProgressRefreshInterval = catalogProgressRefreshInterval
        self.searchDebounceInterval = searchDebounceInterval
        self.thumbnailLoadGate = LibraryThumbnailLoadGate(limit: thumbnailLoadConcurrencyLimit)
    }

    var suggestionThresholdPortForSettings: (any SuggestionThresholdPort)? {
        suggestionThresholds
    }

    var selectedTrainingRun: TrainingRunRecord? {
        guard let selectedTrainingRunID else { return nil }
        return trainingRuns.first(where: { $0.id == selectedTrainingRunID })
    }

    var supportsTrainingWorkspace: Bool {
        trainingWorkspace != nil
    }

    var supportsLibrarySlimming: Bool {
        librarySlimming != nil
    }

    var activeLibrarySlimmingSources: [LibrarySourceSummary] {
        orderedSources.filter { $0.state == .active }
    }

    var canAnalyzeLibrarySlimmingCatalog: Bool {
        supportsLibrarySlimming && !resolvedLibrarySlimmingCatalogSourceIDs.isEmpty
    }

    var librarySlimmingCatalogSourceSelectionTitle: String {
        let active = activeLibrarySlimmingSources
        let selected = resolvedLibrarySlimmingCatalogSources
        guard !selected.isEmpty else { return "未选择来源" }
        if selected.count == active.count {
            return "全部来源（\(active.count)）"
        }
        if selected.count == 1 {
            return selected[0].displayName
        }
        return "已选 \(selected.count) 个来源"
    }

    var librarySlimmingCatalogSourceScopeCaption: String {
        let active = activeLibrarySlimmingSources
        let selected = resolvedLibrarySlimmingCatalogSources
        guard !selected.isEmpty else { return "分析范围：未选择来源" }
        if selected.count == active.count {
            return "分析范围：全部 \(active.count) 个来源"
        }
        return "分析范围：\(selected.map(\.displayName).joined(separator: "、"))"
    }

    var librarySlimmingCatalogAnalyzeActionTitle: String {
        resolvedLibrarySlimmingCatalogSources.count == activeLibrarySlimmingSources.count
            ? "分析全部来源"
            : "分析所选来源"
    }

    var librarySlimmingCatalogAnalyzeRunningTitle: String {
        resolvedLibrarySlimmingCatalogSources.count == activeLibrarySlimmingSources.count
            ? "正在分析全部来源…"
            : "正在分析所选来源…"
    }

    func isLibrarySlimmingCatalogSourceIncluded(_ sourceID: UUID) -> Bool {
        guard activeLibrarySlimmingSources.contains(where: { $0.id == sourceID }) else {
            return false
        }
        guard let selected = librarySlimmingCatalogSourceIDs else { return true }
        return selected.contains(sourceID)
    }

    func setLibrarySlimmingCatalogSourceIncluded(_ sourceID: UUID, _ included: Bool) {
        let activeIDs = Set(activeLibrarySlimmingSources.map(\.id))
        guard activeIDs.contains(sourceID) else { return }
        var selected = librarySlimmingCatalogSourceIDs ?? activeIDs
        if included {
            selected.insert(sourceID)
        } else {
            selected.remove(sourceID)
        }
        selected.formIntersection(activeIDs)
        librarySlimmingCatalogSourceIDs = selected == activeIDs ? nil : selected
    }

    func selectAllLibrarySlimmingCatalogSources() {
        librarySlimmingCatalogSourceIDs = nil
    }

    func clearLibrarySlimmingCatalogSourceSelection() {
        librarySlimmingCatalogSourceIDs = []
    }

    private var resolvedLibrarySlimmingCatalogSources: [LibrarySourceSummary] {
        let active = activeLibrarySlimmingSources
        guard let selected = librarySlimmingCatalogSourceIDs else { return active }
        return active.filter { selected.contains($0.id) }
    }

    private var resolvedLibrarySlimmingCatalogSourceIDs: [UUID] {
        resolvedLibrarySlimmingCatalogSources.map(\.id)
    }

    var supportsResumableLibrarySlimmingAnalysis: Bool {
        librarySlimmingAnalysis != nil
    }

    var supportsSourceSimilarityIndex: Bool {
        librarySlimmingSourceIndex != nil
    }

    /// ADR-045 LS-P10: initialization targets exactly one selected source; ready indexes
    /// may be rebuilt on demand, but a build already in flight must not be duplicated.
    var canInitializeSourceSimilarityIndex: Bool {
        guard librarySlimmingSourceIndex != nil, selectedSourceID != nil else { return false }
        switch sourceSimilarityIndexStatus?.state {
        case nil, .stale, .failed, .ready:
            return true
        case .building:
            return false
        }
    }

    var sourceSimilarityIndexCaption: String? {
        guard supportsSourceSimilarityIndex else { return nil }
        guard selectedSourceID != nil else {
            return "来源索引：请选择单个来源"
        }
        guard let status = sourceSimilarityIndexStatus else {
            return "来源索引：未初始化"
        }
        switch status.state {
        case .building:
            return "来源索引：构建中 \(status.indexedCount)/\(status.assetCount)"
        case .ready:
            return "来源索引：就绪 \(status.indexedCount)/\(status.assetCount) · \(status.clusterCount) 簇"
        case .stale:
            return "来源索引：需要重建"
        case .failed:
            return "来源索引：失败" + (status.lastError.map { "（\($0)）" } ?? "")
        }
    }

    var canPauseLibrarySlimmingAnalysis: Bool {
        guard let selected = selectedLibrarySlimmingAnalysisJob else { return false }
        return selected.state == .running && selected.controlRequest == .none
    }

    var canResumeLibrarySlimmingAnalysis: Bool {
        guard let selected = selectedLibrarySlimmingAnalysisJob else { return false }
        guard !selected.hasResult else { return false }
        switch selected.state {
        case .pending, .paused, .retryableFailed:
            return true
        case .running, .completed, .terminalFailed, .cancelled:
            return false
        }
    }

    var canDeleteSelectedLibrarySlimmingAnalysisJob: Bool {
        guard let selected = selectedLibrarySlimmingAnalysisJob else { return false }
        return selected.state != .running
    }

    var selectedLibrarySlimmingAnalysisJob: LibrarySlimmingAnalysisJobPresentation? {
        guard let id = librarySlimmingAnalysisJobID else { return nil }
        return librarySlimmingAnalysisJobs.first(where: { $0.id == id })
    }

    var supportsLibrarySlimmingRecycle: Bool {
        librarySlimmingRecycle != nil
    }

    var supportsLibrarySlimmingThresholds: Bool {
        librarySlimmingThresholds != nil
    }

    func refreshLibrarySlimmingSceneThresholds() {
        librarySlimmingSceneThresholds = librarySlimmingThresholds?.thresholds() ?? .factory
    }

    func updateLibrarySlimmingSceneThresholds(_ thresholds: NearDuplicateSceneThresholds) {
        guard let librarySlimmingThresholds else { return }
        librarySlimmingThresholds.setThresholds(thresholds)
        librarySlimmingSceneThresholds = librarySlimmingThresholds.thresholds()
        librarySlimmingStatusMessage = "阈值已更新，将在下次分析生效"
    }

    func resetLibrarySlimmingSceneThresholds() {
        guard let librarySlimmingThresholds else { return }
        librarySlimmingThresholds.resetToFactory()
        librarySlimmingSceneThresholds = librarySlimmingThresholds.thresholds()
        librarySlimmingStatusMessage = "已恢复默认阈值，将在下次分析生效"
    }

    var selectedLibrarySlimmingCluster: LibrarySlimmingClusterPresentation? {
        guard let selectedLibrarySlimmingClusterID else { return nil }
        return librarySlimmingClusters.first(where: { $0.id == selectedLibrarySlimmingClusterID })
    }

    func librarySlimmingSourceName(for assetID: UUID) -> String? {
        librarySlimmingMemberSourceNames[assetID]
    }

    var librarySlimmingSelectedClusterSourceSummary: String? {
        guard let cluster = selectedLibrarySlimmingCluster else { return nil }
        var order: [String] = []
        var seen = Set<String>()
        for assetID in cluster.memberAssetIDs {
            guard let sourceName = librarySlimmingMemberSourceNames[assetID] else {
                continue
            }
            if seen.insert(sourceName).inserted {
                order.append(sourceName)
            }
        }
        guard !order.isEmpty else { return nil }
        return order.joined(separator: " · ")
    }

    func selectLibrarySlimmingCluster(_ clusterID: UUID?) {
        selectedLibrarySlimmingClusterID = clusterID
        selectedLibrarySlimmingMemberIDs = []
        librarySlimmingSelectionAnchorID = nil
        refreshSelectedLibrarySlimmingMemberSources()
    }

    func ensureLibrarySlimmingClusterSelection() {
        guard !librarySlimmingClusters.isEmpty,
              selectedLibrarySlimmingCluster == nil
        else { return }
        selectLibrarySlimmingCluster(librarySlimmingClusters.first?.id)
    }

    func selectLibrarySlimmingAnalysisJob(_ jobID: UUID?) {
        guard let jobID else {
            librarySlimmingAnalysisJobID = nil
            librarySlimmingAnalysisJobState = nil
            librarySlimmingAnalysisControlRequest = .none
            librarySlimmingClusters = []
            librarySlimmingMemberSourceNames = [:]
            librarySlimmingPendingCount = 0
            hasCompletedLibrarySlimmingScan = false
            selectedLibrarySlimmingClusterID = nil
            selectedLibrarySlimmingMemberIDs = []
            librarySlimmingSelectionAnchorID = nil
            librarySlimmingSourceLoadTask?.cancel()
            return
        }
        guard librarySlimmingAnalysisJobs.contains(where: { $0.id == jobID }) else { return }
        Task { await loadLibrarySlimmingAnalysisJob(jobID) }
    }

    func refreshSourceSimilarityIndexStatus() async {
        guard let sourceIndex = librarySlimmingSourceIndex, let sourceID = selectedSourceID else {
            sourceSimilarityIndexStatus = nil
            return
        }
        let mediaKind = selectedMediaKind
        do {
            sourceSimilarityIndexStatus = try await Self.offMain {
                try sourceIndex.status(sourceID: sourceID, mediaKind: mediaKind)
            }
        } catch {
            sourceSimilarityIndexStatus = nil
        }
    }

    func initializeSourceSimilarityIndex() async {
        guard let sourceIndex = librarySlimmingSourceIndex,
              let sourceID = selectedSourceID,
              canInitializeSourceSimilarityIndex
        else {
            return
        }
        isInitializingSourceSimilarityIndex = true
        librarySlimmingStatusMessage = "正在为当前来源建立相似索引…"
        let mediaKind = selectedMediaKind
        do {
            _ = try await Self.offMain {
                try sourceIndex.enqueueBuild(sourceID: sourceID, mediaKind: mediaKind)
            }
            await refreshSourceSimilarityIndexStatus()
            try await Self.offMain(priority: .utility) {
                try sourceIndex.runPending()
            }
            await refreshSourceSimilarityIndexStatus()
            if sourceSimilarityIndexStatus?.state == .building {
                startSourceSimilarityIndexAutoRunner()
            } else {
                isInitializingSourceSimilarityIndex = false
                librarySlimmingStatusMessage = sourceSimilarityIndexStatus?.state == .ready
                    ? "来源索引已就绪。"
                    : "来源索引构建未完成，请稍后重试。"
            }
        } catch {
            isInitializingSourceSimilarityIndex = false
            librarySlimmingStatusMessage = "初始化来源索引失败：\(error.localizedDescription)"
        }
    }

    private func startSourceSimilarityIndexAutoRunner() {
        guard sourceSimilarityIndexRunnerTask == nil,
              let sourceIndex = librarySlimmingSourceIndex
        else {
            return
        }
        sourceSimilarityIndexRunnerTask = Task { @MainActor [weak self] in
            defer { self?.sourceSimilarityIndexRunnerTask = nil }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                _ = try? await Self.offMain(priority: .utility) {
                    try sourceIndex.runPending()
                }
                await self?.refreshSourceSimilarityIndexStatus()
                if self?.sourceSimilarityIndexStatus?.state != .building {
                    self?.isInitializingSourceSimilarityIndex = false
                    if self?.sourceSimilarityIndexStatus?.state == .ready {
                        self?.librarySlimmingStatusMessage = "来源索引已就绪。"
                    }
                    return
                }
            }
        }
    }

    func refreshLibrarySlimmingAnalysisJobs() async {
        guard let analysis = librarySlimmingAnalysis else {
            librarySlimmingAnalysisJobs = []
            return
        }
        let mediaKind = selectedMediaKind
        do {
            let jobs = try await Self.offMain {
                try analysis.listJobs(mediaKind: mediaKind)
            }
            librarySlimmingAnalysisJobs = jobs.map(LibrarySlimmingAnalysisJobPresentation.init)
            if let selected = librarySlimmingAnalysisJobID,
               !librarySlimmingAnalysisJobs.contains(where: { $0.id == selected })
            {
                if let latest = librarySlimmingAnalysisJobs.first {
                    await loadLibrarySlimmingAnalysisJob(latest.id)
                } else {
                    selectLibrarySlimmingAnalysisJob(nil)
                }
            }
            ensureLibrarySlimmingClusterSelection()
        } catch {
            librarySlimmingStatusMessage = "无法加载分析记录：\(error.localizedDescription)"
        }
    }

    func deleteLibrarySlimmingAnalysisJob(_ jobID: UUID) async {
        guard let analysis = librarySlimmingAnalysis else { return }
        do {
            try await Self.offMain {
                try analysis.delete(jobID: jobID)
            }
            let wasSelected = librarySlimmingAnalysisJobID == jobID
            librarySlimmingAnalysisJobs.removeAll { $0.id == jobID }
            if wasSelected {
                if let next = librarySlimmingAnalysisJobs.first {
                    await loadLibrarySlimmingAnalysisJob(next.id)
                } else {
                    selectLibrarySlimmingAnalysisJob(nil)
                    librarySlimmingStatusMessage = "已删除分析记录。"
                }
            } else {
                librarySlimmingStatusMessage = "已删除分析记录。"
            }
        } catch {
            librarySlimmingStatusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func loadLibrarySlimmingAnalysisJob(
        _ jobID: UUID,
        forceSelect: Bool = true
    ) async {
        guard let analysis = librarySlimmingAnalysis else { return }
        do {
            let snapshot = try await Self.offMain {
                try analysis.snapshot(jobID: jobID)
            }
            applyLibrarySlimmingJobSnapshot(snapshot, forceSelect: forceSelect)
        } catch {
            librarySlimmingStatusMessage = "无法打开分析记录：\(error.localizedDescription)"
        }
    }

    func selectLibrarySlimmingMember(
        _ assetID: UUID,
        additive: Bool,
        extendRange: Bool = false
    ) {
        guard let cluster = selectedLibrarySlimmingCluster,
              cluster.memberAssetIDs.contains(assetID)
        else { return }
        if extendRange,
           let anchorID = librarySlimmingSelectionAnchorID,
           let anchorIndex = cluster.memberAssetIDs.firstIndex(of: anchorID),
           let targetIndex = cluster.memberAssetIDs.firstIndex(of: assetID)
        {
            let range = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
            let rangeIDs = Set(range.map { cluster.memberAssetIDs[$0] })
            selectedLibrarySlimmingMemberIDs = additive
                ? selectedLibrarySlimmingMemberIDs.union(rangeIDs)
                : rangeIDs
        } else if additive {
            if selectedLibrarySlimmingMemberIDs.contains(assetID) {
                selectedLibrarySlimmingMemberIDs.remove(assetID)
            } else {
                selectedLibrarySlimmingMemberIDs.insert(assetID)
            }
            librarySlimmingSelectionAnchorID = assetID
        } else {
            selectedLibrarySlimmingMemberIDs = [assetID]
            librarySlimmingSelectionAnchorID = assetID
        }
    }

    func selectLibrarySlimmingMembers(
        _ assetIDs: Set<UUID>,
        additive: Bool = false
    ) {
        guard let cluster = selectedLibrarySlimmingCluster else { return }
        let normalizedIDs = assetIDs.intersection(cluster.memberAssetIDs)
        if additive {
            selectedLibrarySlimmingMemberIDs.formUnion(normalizedIDs)
        } else {
            selectedLibrarySlimmingMemberIDs = normalizedIDs
        }
        librarySlimmingSelectionAnchorID = cluster.memberAssetIDs.first {
            selectedLibrarySlimmingMemberIDs.contains($0)
        }
    }

    var canFindLibrarySlimmingFromSelection: Bool {
        supportsLibrarySlimming && !selectedAssetIDs.isEmpty
    }

    /// Sidebar destination plus gallery filters always define a scan universe for current-filter analysis.
    var hasLibrarySlimmingFilterScope: Bool {
        true
    }

    /// Whether seed lookup should search a narrowed universe instead of the full available catalog.
    var hasNarrowedLibrarySlimmingUniverse: Bool {
        tagPresence != .any
            || selectedSourceID != nil
            || hasActiveTagFilters
            || !selectedAvailabilities.isEmpty
            || !selectedMediaTypes.isEmpty
            || !TagNameNormalizer.trimUnicodeWhiteSpace(searchText).isEmpty
    }

    var librarySlimmingFilterScopeSummary: String {
        var parts: [String] = [browsingTitle]
        if let tagSummary = tagFilterSummaryText() {
            parts.append(tagSummary)
        }
        let trimmedSearch = TagNameNormalizer.trimUnicodeWhiteSpace(searchText)
        if !trimmedSearch.isEmpty {
            parts.append("搜索「\(trimmedSearch)」")
        }
        if !selectedAvailabilities.isEmpty {
            let names = selectedAvailabilities
                .map(LibraryAssetDetailText.availabilityText)
                .joined(separator: "、")
            parts.append("可用性：\(names)")
        }
        if !selectedMediaTypes.isEmpty {
            parts.append("格式筛选")
        }
        return parts.joined(separator: " · ")
    }

    var librarySlimmingCurrentFilterActionTitle: String {
        guard let selectedSourceID,
              let source = sources.first(where: { $0.id == selectedSourceID })
        else {
            return "分析当前筛选"
        }
        return "分析来源：\(source.displayName)"
    }

    var librarySlimmingCurrentFilterRunningTitle: String {
        guard let selectedSourceID,
              let source = sources.first(where: { $0.id == selectedSourceID })
        else {
            return "正在分析当前筛选…"
        }
        return "正在分析：\(source.displayName)…"
    }

    var librarySlimmingFilterScopeCaption: String {
        "筛选范围：\(librarySlimmingFilterScopeSummary)"
    }

    func findLibrarySlimmingFromSelection() async {
        guard canFindLibrarySlimmingFromSelection else { return }
        librarySlimmingSeedAssetIDs = selectedAssetIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        librarySlimmingAnalyzeMode = .seeds
        shouldAutoAnalyzeLibrarySlimmingSeeds = true
        librarySlimmingNavigationNonce = UUID()
    }

    func bindPendingLibrarySlimmingSeedAnalyzeIfNeeded(to navigationRequestID: UUID) {
        guard shouldAutoAnalyzeLibrarySlimmingSeeds else { return }
        librarySlimmingSeedAnalyzeNavigationRequestID = navigationRequestID
    }

    func cancelPendingLibrarySlimmingSeedAnalyze() {
        shouldAutoAnalyzeLibrarySlimmingSeeds = false
        librarySlimmingSeedAnalyzeNavigationRequestID = nil
    }

    func consumePendingLibrarySlimmingSeedAnalyzeIfNeeded(
        navigationRequestID: UUID? = nil
    ) async {
        if let navigationRequestID {
            guard shouldAutoAnalyzeLibrarySlimmingSeeds,
                  librarySlimmingSeedAnalyzeNavigationRequestID == navigationRequestID
            else { return }
        } else {
            guard shouldAutoAnalyzeLibrarySlimmingSeeds else { return }
        }
        cancelPendingLibrarySlimmingSeedAnalyze()
        await analyzeLibrarySlimming(mode: .seeds)
    }

    func selectLibrarySlimmingWorkspaceTab(_ tab: LibrarySlimmingWorkspaceTab) {
        librarySlimmingWorkspaceTab = tab
        if tab == .recycleBin {
            Task { await refreshLibrarySlimmingRecycleEntries() }
        }
    }

    func refreshLibrarySlimmingRecycleEntries() async {
        guard let recycle = librarySlimmingRecycle else {
            librarySlimmingRecycleEntries = []
            return
        }
        let mediaKind = selectedMediaKind
        do {
            let entries = try await Self.offMain {
                _ = try recycle.reconcilePhotosRecycleEntries()
                return try recycle.listRecycledEntries()
            }
            librarySlimmingRecycleEntries = entries.filter { $0.mediaKind == mediaKind }
        } catch {
            librarySlimmingStatusMessage = "无法加载回收站：\(error.localizedDescription)"
        }
    }

    var skipsLibrarySlimmingMoveToRecycleConfirmation: Bool {
        librarySlimmingRecycleConfirmationPreferences.skipsMoveConfirmation
    }

    func setSkipsLibrarySlimmingMoveToRecycleConfirmation(_ skips: Bool) {
        librarySlimmingRecycleConfirmationPreferences.skipsMoveConfirmation = skips
    }

    var canMoveSelectedLibrarySlimmingMembersToRecycle: Bool {
        librarySlimmingMoveToRecycleDisabledReason == nil
    }

    var librarySlimmingIdenticalGroupCount: Int {
        librarySlimmingClusters.filter { $0.kind == .byteIdentical }.count
    }

    var isRunningLibrarySlimmingIdenticalCleanup: Bool {
        librarySlimmingIdenticalCleanupExecutionProgress != nil
    }

    var canPrepareLibrarySlimmingIdenticalCleanup: Bool {
        librarySlimmingIdenticalCleanupDisabledReason == nil
    }

    var librarySlimmingIdenticalCleanupDisabledReason: String? {
        if !supportsLibrarySlimmingRecycle {
            return "回收站服务未就绪"
        }
        if librarySlimmingIdenticalGroupCount == 0 {
            return "当前分析结果中没有完全相同分组"
        }
        if isPreparingLibrarySlimmingIdenticalCleanup {
            return "正在计算清理方案…"
        }
        if isAnalyzingLibrarySlimming {
            return "请先等待当前分析完成或暂停"
        }
        if isCatalogScanning {
            return "请先等待照片来源刷新完成"
        }
        if isInitializingSourceSimilarityIndex {
            return "请先等待来源索引初始化完成"
        }
        if isMutatingLibrarySlimmingRecycle {
            return "正在移入回收站…"
        }
        return nil
    }

    var librarySlimmingMoveToRecycleDisabledReason: String? {
        if !supportsLibrarySlimmingRecycle {
            return "回收站服务未就绪"
        }
        if selectedLibrarySlimmingMemberIDs.isEmpty {
            return "请先选择要移入回收站的照片"
        }
        if isMutatingLibrarySlimmingRecycle {
            return "正在移入回收站…"
        }
        return nil
    }

    func moveSelectedLibrarySlimmingMembersToRecycle() async {
        guard canMoveSelectedLibrarySlimmingMembersToRecycle,
              !selectedLibrarySlimmingMemberIDs.isEmpty
        else { return }
        await moveLibrarySlimmingAssetsToRecycle(
            Array(selectedLibrarySlimmingMemberIDs),
            identicalCleanupPlan: nil
        )
    }

    func prepareLibrarySlimmingIdenticalCleanup()
        async -> LibrarySlimmingIdenticalCleanupPlan?
    {
        guard canPrepareLibrarySlimmingIdenticalCleanup,
              let recycle = librarySlimmingRecycle
        else { return nil }
        isPreparingLibrarySlimmingIdenticalCleanup = true
        librarySlimmingRecycleActionMessage = nil
        librarySlimmingIdenticalCleanupPostDeleteReport = nil
        defer { isPreparingLibrarySlimmingIdenticalCleanup = false }
        do {
            let clusters = librarySlimmingClusters.map(\.cluster)
            let plan = try await Self.offMain {
                try recycle.makeIdenticalCleanupPlan(clusters: clusters)
            }
            guard !plan.isEmpty else {
                let skipped = plan.skippedGroupCount > 0
                    ? "；另有 \(plan.skippedGroupCount) 组因来源状态变化已跳过"
                    : ""
                let message = "当前没有可安全清理的完全相同照片\(skipped)"
                librarySlimmingStatusMessage = message
                librarySlimmingRecycleActionMessage = message
                return nil
            }
            return plan
        } catch {
            let message = "无法生成一键清理方案：\(error.localizedDescription)"
            librarySlimmingStatusMessage = message
            librarySlimmingRecycleActionMessage = message
            return nil
        }
    }

    func moveLibrarySlimmingIdenticalRedundancyToRecycle(
        plan: LibrarySlimmingIdenticalCleanupPlan
    ) async {
        guard !plan.isEmpty,
              canPrepareLibrarySlimmingIdenticalCleanup,
              !isRunningLibrarySlimmingIdenticalCleanup,
              !isMutatingLibrarySlimmingRecycle,
              let recycle = librarySlimmingRecycle
        else { return }
        let executionID = UUID()
        librarySlimmingIdenticalCleanupExecutionID = executionID
        librarySlimmingIdenticalCleanupExecutionProgress =
            LibrarySlimmingIdenticalCleanupExecutionProgress(
                phase: .validatingPlan,
                completedAssetCount: 0,
                totalAssetCount: plan.assetIDsToRecycle.count
            )
        isMutatingLibrarySlimmingRecycle = true
        defer {
            isMutatingLibrarySlimmingRecycle = false
            finishLibrarySlimmingIdenticalCleanupExecution(executionID: executionID)
        }
        do {
            let clusters = librarySlimmingClusters.map(\.cluster)
            let refreshedPlan = try await Self.offMain {
                try recycle.makeIdenticalCleanupPlan(clusters: clusters)
            }
            guard refreshedPlan == plan else {
                let message = "分析结果或来源状态已变化，请重新预览一键清理方案。"
                librarySlimmingStatusMessage = message
                librarySlimmingRecycleActionMessage = message
                return
            }
        } catch {
            let message = "无法复核一键清理方案：\(error.localizedDescription)"
            librarySlimmingStatusMessage = message
            librarySlimmingRecycleActionMessage = message
            return
        }
        await moveLibrarySlimmingAssetsToRecycle(
            plan.assetIDsToRecycle,
            identicalCleanupPlan: plan,
            mutationStateAlreadyHeld: true
        )
    }

    func dismissLibrarySlimmingIdenticalCleanupPostDeleteReport() {
        librarySlimmingIdenticalCleanupPostDeleteReport = nil
    }

    private func moveLibrarySlimmingAssetsToRecycle(
        _ assetIDs: [UUID],
        identicalCleanupPlan: LibrarySlimmingIdenticalCleanupPlan?,
        mutationStateAlreadyHeld: Bool = false
    ) async {
        guard !assetIDs.isEmpty,
              let recycle = librarySlimmingRecycle
        else { return }
        if mutationStateAlreadyHeld {
            guard isMutatingLibrarySlimmingRecycle else { return }
        } else {
            guard !isMutatingLibrarySlimmingRecycle else { return }
            isMutatingLibrarySlimmingRecycle = true
        }
        librarySlimmingRecycleActionMessage = nil
        defer {
            if !mutationStateAlreadyHeld {
                isMutatingLibrarySlimmingRecycle = false
            }
        }
        do {
            let cleanupExecutionID = identicalCleanupPlan == nil
                ? nil
                : librarySlimmingIdenticalCleanupExecutionID
            let totalAssetCount = assetIDs.count
            if let cleanupExecutionID {
                setLibrarySlimmingIdenticalCleanupExecutionPhase(
                    .recyclingAssets,
                    completedAssetCount: 0,
                    totalAssetCount: totalAssetCount,
                    executionID: cleanupExecutionID
                )
            }
            let initialProgressHandler = makeLibrarySlimmingRecycleProgressHandler(
                executionID: cleanupExecutionID,
                baseCompletedAssetCount: 0,
                overallTotalAssetCount: totalAssetCount
            )
            var outcome = try await Self.offMain {
                try recycle.moveAssetsToRecycle(
                    assetIDs: assetIDs,
                    onProgress: initialProgressHandler
                )
            }
            if !outcome.authorizationRequiredSourceIDs.isEmpty,
               let mutationAuthorization = librarySlimmingMutationAuthorization
            {
                if let cleanupExecutionID {
                    setLibrarySlimmingIdenticalCleanupExecutionPhase(
                        .requestingAuthorization,
                        totalAssetCount: totalAssetCount,
                        executionID: cleanupExecutionID
                    )
                }
                var authorizedAtLeastOneSource = false
                for sourceID in outcome.authorizationRequiredSourceIDs {
                    do {
                        if case .authorized = try await mutationAuthorization.authorizeMutation(
                            sourceID: sourceID
                        ) {
                            authorizedAtLeastOneSource = true
                        }
                    } catch {
                        continue
                    }
                }
                if authorizedAtLeastOneSource, !outcome.authorizationRequiredAssetIDs.isEmpty {
                    let retryAssetIDs = outcome.authorizationRequiredAssetIDs
                    let baseCompletedAssetCount = completedLibrarySlimmingRecycleAssetCount(
                        totalAssetCount: totalAssetCount,
                        outcome: outcome
                    )
                    if let cleanupExecutionID {
                        setLibrarySlimmingIdenticalCleanupExecutionPhase(
                            .recyclingAssets,
                            completedAssetCount: baseCompletedAssetCount,
                            totalAssetCount: totalAssetCount,
                            executionID: cleanupExecutionID
                        )
                    }
                    let retryProgressHandler = makeLibrarySlimmingRecycleProgressHandler(
                        executionID: cleanupExecutionID,
                        baseCompletedAssetCount: baseCompletedAssetCount,
                        overallTotalAssetCount: totalAssetCount
                    )
                    let authorizationFailures = Set(retryAssetIDs)
                    let otherFailedAssetIDs = outcome.failedAssetIDs.filter {
                        !authorizationFailures.contains($0)
                    }
                    let retry = try await Self.offMain {
                        try recycle.moveAssetsToRecycle(
                            assetIDs: retryAssetIDs,
                            onProgress: retryProgressHandler
                        )
                    }
                    outcome.recycledEntryIDs.append(contentsOf: retry.recycledEntryIDs)
                    outcome.skippedPhotosAssetIDs.append(contentsOf: retry.skippedPhotosAssetIDs)
                    outcome.authorizationDeniedPhotosAssetIDs.append(
                        contentsOf: retry.authorizationDeniedPhotosAssetIDs
                    )
                    outcome.failedAssetIDs = otherFailedAssetIDs + retry.failedAssetIDs
                    outcome.authorizationRequiredSourceIDs = retry.authorizationRequiredSourceIDs
                    outcome.authorizationRequiredAssetIDs = retry.authorizationRequiredAssetIDs
                }
            }
            if !outcome.authorizationDeniedPhotosAssetIDs.isEmpty,
               let photosLibraryMutation
            {
                if let cleanupExecutionID {
                    setLibrarySlimmingIdenticalCleanupExecutionPhase(
                        .requestingAuthorization,
                        totalAssetCount: totalAssetCount,
                        executionID: cleanupExecutionID
                    )
                }
                let auth = await photosLibraryMutation.requestAuthorization()
                if auth == .authorized {
                    let retryAssetIDs = outcome.authorizationDeniedPhotosAssetIDs
                    let baseCompletedAssetCount = completedLibrarySlimmingRecycleAssetCount(
                        totalAssetCount: totalAssetCount,
                        outcome: outcome
                    )
                    if let cleanupExecutionID {
                        setLibrarySlimmingIdenticalCleanupExecutionPhase(
                            .recyclingAssets,
                            completedAssetCount: baseCompletedAssetCount,
                            totalAssetCount: totalAssetCount,
                            executionID: cleanupExecutionID
                        )
                    }
                    let retryProgressHandler = makeLibrarySlimmingRecycleProgressHandler(
                        executionID: cleanupExecutionID,
                        baseCompletedAssetCount: baseCompletedAssetCount,
                        overallTotalAssetCount: totalAssetCount
                    )
                    let photosAuthorizationFailures = Set(retryAssetIDs)
                    let otherFailedAssetIDs = outcome.failedAssetIDs.filter {
                        !photosAuthorizationFailures.contains($0)
                    }
                    let retry = try await Self.offMain {
                        try recycle.moveAssetsToRecycle(
                            assetIDs: retryAssetIDs,
                            onProgress: retryProgressHandler
                        )
                    }
                    outcome.recycledEntryIDs.append(contentsOf: retry.recycledEntryIDs)
                    outcome.skippedPhotosAssetIDs.append(contentsOf: retry.skippedPhotosAssetIDs)
                    outcome.authorizationDeniedPhotosAssetIDs =
                        retry.authorizationDeniedPhotosAssetIDs
                    outcome.failedAssetIDs = otherFailedAssetIDs + retry.failedAssetIDs
                    outcome.authorizationRequiredSourceIDs.append(
                        contentsOf: retry.authorizationRequiredSourceIDs
                    )
                    outcome.authorizationRequiredAssetIDs.append(
                        contentsOf: retry.authorizationRequiredAssetIDs
                    )
                }
            }
            if let cleanupExecutionID {
                setLibrarySlimmingIdenticalCleanupExecutionPhase(
                    .refreshingState,
                    totalAssetCount: totalAssetCount,
                    executionID: cleanupExecutionID
                )
            }
            let recycled = try await Self.offMain {
                try recycle.slimmingHiddenAssetIDs(from: assetIDs)
            }
            noteLibrarySlimmingCatalogMutation(assetIDs: recycled)
            invalidateRecycledAssetsInActiveWorkspace(recycled)
            selectedLibrarySlimmingMemberIDs.subtract(recycled)
            if let anchorID = librarySlimmingSelectionAnchorID,
               recycled.contains(anchorID)
            {
                librarySlimmingSelectionAnchorID = nil
            }
            librarySlimmingClusters = filterLibrarySlimmingClustersRemoving(
                assetIDs: recycled,
                from: librarySlimmingClusters
            )
            if let selected = selectedLibrarySlimmingClusterID,
               !librarySlimmingClusters.contains(where: { $0.id == selected })
            {
                selectedLibrarySlimmingClusterID = librarySlimmingClusters.first?.id
            }
            refreshSelectedLibrarySlimmingMemberSources()
            var parts: [String] = []
            if let identicalCleanupPlan {
                let completedGroups = identicalCleanupPlan.decisions.filter { decision in
                    Set(decision.assetIDsToRecycle).isSubset(of: recycled)
                }.count
                if completedGroups == identicalCleanupPlan.groupCount {
                    parts.append("已清理 \(completedGroups) 组完全相同照片")
                } else if completedGroups > 0 {
                    parts.append(
                        "已清理 \(completedGroups)/\(identicalCleanupPlan.groupCount) 组完全相同照片"
                    )
                }
            }
            if !outcome.recycledEntryIDs.isEmpty {
                parts.append("已移入回收站 \(outcome.recycledEntryIDs.count) 张")
            }
            if !outcome.authorizationDeniedPhotosAssetIDs.isEmpty {
                parts.append(
                    "Photos 未授权 \(outcome.authorizationDeniedPhotosAssetIDs.count) 张，请在系统设置中允许 ImageAll 访问照片库"
                )
            }
            if !outcome.authorizationRequiredSourceIDs.isEmpty {
                parts.append("部分来源需要写入授权")
            }
            if !outcome.failedAssetIDs.isEmpty {
                if outcome.recycledEntryIDs.isEmpty,
                   outcome.authorizationRequiredSourceIDs.isEmpty,
                   outcome.authorizationDeniedPhotosAssetIDs.isEmpty
                {
                    parts.append(
                        "失败 \(outcome.failedAssetIDs.count) 张（已有来源权限不可用；请从左侧来源菜单更新回收权限后重试）"
                    )
                } else {
                    parts.append("失败 \(outcome.failedAssetIDs.count) 张")
                }
            }
            let message = parts.isEmpty ? "未移动任何照片" : parts.joined(separator: " · ")
            librarySlimmingStatusMessage = message
            librarySlimmingRecycleActionMessage = message
            await refreshLibrarySlimmingRecycleEntries()
            noteLibrarySlimmingCatalogMutation(assetIDs: recycled)
            if let identicalCleanupPlan {
                if let cleanupExecutionID {
                    setLibrarySlimmingIdenticalCleanupExecutionPhase(
                        .verifyingResult,
                        totalAssetCount: totalAssetCount,
                        executionID: cleanupExecutionID
                    )
                }
                await verifyLibrarySlimmingIdenticalCleanupAfterDeletion(
                    plan: identicalCleanupPlan,
                    recycle: recycle
                )
            }
            _ = try? await Self.offMain {
                try recycle.enqueuePurgeExpired()
            }
        } catch {
            let message = "移入回收站失败：\(error.localizedDescription)"
            librarySlimmingStatusMessage = message
            librarySlimmingRecycleActionMessage = message
            if let identicalCleanupPlan {
                if let executionID = librarySlimmingIdenticalCleanupExecutionID {
                    setLibrarySlimmingIdenticalCleanupExecutionPhase(
                        .verifyingResult,
                        totalAssetCount: assetIDs.count,
                        executionID: executionID
                    )
                }
                await verifyLibrarySlimmingIdenticalCleanupAfterDeletion(
                    plan: identicalCleanupPlan,
                    recycle: recycle
                )
            }
        }
    }

    private func setLibrarySlimmingIdenticalCleanupExecutionPhase(
        _ phase: LibrarySlimmingIdenticalCleanupExecutionProgress.Phase,
        completedAssetCount: Int = 0,
        totalAssetCount: Int,
        executionID: UUID
    ) {
        guard librarySlimmingIdenticalCleanupExecutionID == executionID else { return }
        librarySlimmingIdenticalCleanupExecutionProgress =
            LibrarySlimmingIdenticalCleanupExecutionProgress(
                phase: phase,
                completedAssetCount: min(
                    max(0, completedAssetCount),
                    max(0, totalAssetCount)
                ),
                totalAssetCount: max(0, totalAssetCount)
            )
    }

    private func makeLibrarySlimmingRecycleProgressHandler(
        executionID: UUID?,
        baseCompletedAssetCount: Int,
        overallTotalAssetCount: Int
    ) -> LibrarySlimmingRecycleMoveProgressHandler {
        { [weak self] progress in
            guard let executionID else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.librarySlimmingIdenticalCleanupExecutionID == executionID,
                      self.librarySlimmingIdenticalCleanupExecutionProgress?.phase
                        == .recyclingAssets
                else { return }
                self.setLibrarySlimmingIdenticalCleanupExecutionPhase(
                    .recyclingAssets,
                    completedAssetCount: baseCompletedAssetCount
                        + progress.completedAssetCount,
                    totalAssetCount: overallTotalAssetCount,
                    executionID: executionID
                )
            }
        }
    }

    private func completedLibrarySlimmingRecycleAssetCount(
        totalAssetCount: Int,
        outcome: LibrarySlimmingRecycleMoveOutcome
    ) -> Int {
        let retryableAssetIDs = Set(outcome.authorizationRequiredAssetIDs)
            .union(outcome.authorizationDeniedPhotosAssetIDs)
        return max(0, totalAssetCount - retryableAssetIDs.count)
    }

    private func finishLibrarySlimmingIdenticalCleanupExecution(executionID: UUID) {
        guard librarySlimmingIdenticalCleanupExecutionID == executionID else { return }
        librarySlimmingIdenticalCleanupExecutionProgress = nil
        librarySlimmingIdenticalCleanupExecutionID = nil
    }

    private func verifyLibrarySlimmingIdenticalCleanupAfterDeletion(
        plan: LibrarySlimmingIdenticalCleanupPlan,
        recycle: any LibrarySlimmingRecyclePort
    ) async {
        do {
            let verification = try await Self.offMain {
                try recycle.verifyIdenticalCleanup(plan: plan)
            }
            librarySlimmingIdenticalCleanupPostDeleteReport = .verified(verification)
            var parts = [
                "已完成去重 \(verification.verifiedGroupCount)/\(verification.targetGroupCount) 组",
                "已移入回收站 \(verification.recycledRedundantAssetCount) 张",
            ]
            if verification.unresolvedGroupCount > 0 {
                parts.append("尚未完成 \(verification.unresolvedGroupCount) 组")
            }
            if verification.remainingRedundantAssetCount > 0 {
                parts.append("仍有冗余 \(verification.remainingRedundantAssetCount) 张")
            }
            if verification.unresolvedAssetCount > 0 {
                parts.append("状态待确认 \(verification.unresolvedAssetCount) 张")
            }
            let message = parts.joined(separator: " · ")
            librarySlimmingStatusMessage = message
            librarySlimmingRecycleActionMessage = message
        } catch {
            librarySlimmingIdenticalCleanupPostDeleteReport = .unavailable(
                message: "删除动作已经结束，但无法读取删除后的实际资产状态：\(error.localizedDescription)"
            )
        }
    }

    private func invalidateRecycledAssetsInActiveWorkspace(_ assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        hiddenRecycledAssetIDs.formUnion(assetIDs)

        // A query that started before the database transaction may still carry
        // an available projection. Invalidate those completions before changing
        // the visible collections so they cannot make a recycled asset flash back.
        assetPageRequestID = UUID()
        reviewPageRequestID = UUID()

        let removedSelectedReviewItem = selectedReviewItemID.map { selectedID in
            reviewQueueItems.contains {
                $0.id == selectedID && assetIDs.contains($0.assetID)
            }
        } ?? false

        items.removeAll { assetIDs.contains($0.assetID) }
        reviewQueueItems.removeAll { assetIDs.contains($0.assetID) }
        selectedAssetIDs.subtract(assetIDs)
        librarySlimmingSeedAssetIDs.removeAll { assetIDs.contains($0) }

        if removedSelectedReviewItem {
            selectedReviewItemID = nil
        }
        if let selectionAnchorID, assetIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
        if let inspectorAssetID = inspectorDetail?.assetID,
           assetIDs.contains(inspectorAssetID)
        {
            inspectorDetail = nil
            inspectorTags = []
            assetPendingSuggestions = []
        }
        if selectedAssetIDs.isEmpty {
            isSinglePhotoPresented = false
        }

        resetCloudPreviewIfSelectionChanged()
        resetLocalModelSuggestionsForSelection()
    }

    func restoreLibrarySlimmingRecycleEntry(_ entryID: UUID) async {
        guard let recycle = librarySlimmingRecycle else { return }
        let entry = librarySlimmingRecycleEntries.first(where: { $0.id == entryID })
        isMutatingLibrarySlimmingRecycle = true
        defer { isMutatingLibrarySlimmingRecycle = false }
        do {
            try await Self.offMain {
                try recycle.restore(entryID: entryID)
            }
            if let entry {
                hiddenRecycledAssetIDs.remove(entry.assetID)
                markLibrarySlimmingThumbnailForReload(entry.assetID)
            }
            librarySlimmingStatusMessage = "已从回收站恢复"
            await refreshLibrarySlimmingRecycleEntries()
            await refreshActiveWorkspaceAfterRecycleRestore()
        } catch LibrarySlimmingRecycleError.photosRestoreRequiresPhotosApp {
            librarySlimmingStatusMessage =
                "Photos 资产需在系统「照片 → 最近删除」中恢复；恢复后将自动对账"
            await refreshLibrarySlimmingRecycleEntries()
        } catch LibrarySlimmingRecycleError.photosAuthorizationRequired {
            librarySlimmingStatusMessage = "恢复失败：需要 Photos 读写授权"
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            librarySlimmingStatusMessage =
                "恢复失败：已有来源权限不可用，请从左侧来源菜单更新回收权限后重试"
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            guard let sourceID = entry?.sourceID,
                  let mutationAuthorization = librarySlimmingMutationAuthorization
            else {
                librarySlimmingStatusMessage = "恢复失败：需要重新授权来源写入权限"
                return
            }
            do {
                guard case .authorized = try await mutationAuthorization.authorizeMutation(
                    sourceID: sourceID
                ) else {
                    librarySlimmingStatusMessage = "已取消写入授权，照片仍保留在回收站"
                    return
                }
                try await Self.offMain {
                    try recycle.restore(entryID: entryID)
                }
                if let entry {
                    hiddenRecycledAssetIDs.remove(entry.assetID)
                    markLibrarySlimmingThumbnailForReload(entry.assetID)
                }
                librarySlimmingStatusMessage = "已从回收站恢复"
                await refreshLibrarySlimmingRecycleEntries()
                await refreshActiveWorkspaceAfterRecycleRestore()
            } catch LibrarySlimmingRecycleError.restoreConflict {
                librarySlimmingStatusMessage = "恢复失败：原路径已存在文件"
            } catch LibrarySlimmingRecycleError.photosRestoreRequiresPhotosApp {
                librarySlimmingStatusMessage =
                    "Photos 资产需在系统「照片 → 最近删除」中恢复；恢复后将自动对账"
                await refreshLibrarySlimmingRecycleEntries()
            } catch {
                librarySlimmingStatusMessage = "恢复失败：\(error.localizedDescription)"
            }
        } catch LibrarySlimmingRecycleError.restoreConflict {
            librarySlimmingStatusMessage = "恢复失败：原路径已存在文件"
        } catch {
            librarySlimmingStatusMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    private func refreshActiveWorkspaceAfterRecycleRestore() async {
        await loadFirstPage(remountGrid: false)
        await refreshReviewState()
        if let selectedJobID = librarySlimmingAnalysisJobID {
            await loadLibrarySlimmingAnalysisJob(selectedJobID, forceSelect: false)
        }
    }

    func librarySlimmingThumbnailReloadVersion(for assetID: UUID) -> Int {
        librarySlimmingThumbnailReloadVersions[assetID, default: 0]
    }

    private func markLibrarySlimmingThumbnailForReload(_ assetID: UUID) {
        librarySlimmingThumbnailReloadVersions[assetID, default: 0] &+= 1
    }

    func purgeLibrarySlimmingRecycleEntry(_ entryID: UUID) async {
        guard let recycle = librarySlimmingRecycle else { return }
        isMutatingLibrarySlimmingRecycle = true
        defer { isMutatingLibrarySlimmingRecycle = false }
        do {
            try await Self.offMain {
                try recycle.purgeNow(entryID: entryID)
            }
            librarySlimmingStatusMessage = "已永久删除"
            await refreshLibrarySlimmingRecycleEntries()
        } catch LibrarySlimmingRecycleError.photosManagedBySystem {
            librarySlimmingStatusMessage =
                "Photos 资产的恢复和永久删除由系统「照片」App 管理"
        } catch {
            librarySlimmingStatusMessage = "永久删除失败：\(error.localizedDescription)"
        }
    }

    func analyzeLibrarySlimming(mode: LibrarySlimmingAnalyzeMode? = nil) async {
        guard let librarySlimming else { return }
        let resolvedMode = mode ?? librarySlimmingAnalyzeMode
        let catalogSourceIDs = resolvedLibrarySlimmingCatalogSourceIDs
        if resolvedMode == .catalog, catalogSourceIDs.isEmpty {
            librarySlimmingStatusMessage = "请至少选择一个要分析的来源。"
            return
        }
        if let librarySlimmingAnalysis {
            await analyzeLibrarySlimmingWithJob(
                analysis: librarySlimmingAnalysis,
                mode: resolvedMode,
                catalogSourceIDs: catalogSourceIDs
            )
            return
        }
        guard !isAnalyzingLibrarySlimming else { return }
        librarySlimmingAnalyzeMode = resolvedMode
        isAnalyzingLibrarySlimming = true
        hasCompletedLibrarySlimmingScan = false
        let mediaKind = selectedMediaKind
        let mediaNoun = mediaKind == .video ? "视频" : "照片"
        librarySlimmingStatusMessage = "正在分析相同与相似\(mediaNoun)…"
        librarySlimmingScanProgress = nil
        selectedLibrarySlimmingMemberIDs = []
        librarySlimmingSelectionAnchorID = nil
        defer {
            isAnalyzingLibrarySlimming = false
            librarySlimmingScanProgress = nil
        }
        do {
            let progressHandler: LibrarySlimmingScanProgressHandler = { [weak self] progress in
                Task { @MainActor in
                    self?.librarySlimmingScanProgress = progress
                    self?.librarySlimmingStatusMessage = progress.caption
                }
            }
            let scanPort = librarySlimming
            let workspaceService = service
            let result: LibrarySlimmingScanResult
            switch resolvedMode {
            case .catalog:
                let filter = AssetPageFilter(
                    sourceIDs: catalogSourceIDs,
                    availabilities: [.available],
                    mediaKinds: [mediaKind]
                )
                result = try await Self.offMain {
                    let assetIDs = try Self.listAllAssetIDs(
                        service: workspaceService,
                        filter: filter,
                        sort: .newest
                    )
                    return try scanPort.scan(
                        assetIDs: assetIDs,
                        mediaKind: mediaKind,
                        onProgress: progressHandler
                    )
                }
            case .currentFilter:
                let filter = currentFilter
                let pageSort = sort
                result = try await Self.offMain {
                    let assetIDs = try Self.listAllAssetIDs(
                        service: workspaceService,
                        filter: filter,
                        sort: pageSort
                    )
                    return try scanPort.scan(
                        assetIDs: assetIDs,
                        mediaKind: mediaKind,
                        onProgress: progressHandler
                    )
                }
            case .seeds:
                let seeds = librarySlimmingSeedAssetIDs
                guard !seeds.isEmpty else {
                    librarySlimmingStatusMessage = "请先在图库中选择种子\(mediaNoun)。"
                    return
                }
                let narrowed = hasNarrowedLibrarySlimmingUniverse
                let filter = narrowed
                    ? currentFilter
                    : AssetPageFilter(availabilities: [.available], mediaKinds: [mediaKind])
                let pageSort = narrowed ? sort : AssetPageSort.newest
                result = try await Self.offMain {
                    let universe = try Self.listAllAssetIDs(
                        service: workspaceService,
                        filter: filter,
                        sort: pageSort
                    )
                    return try scanPort.scanSeeds(
                        seedAssetIDs: seeds,
                        universeAssetIDs: universe,
                        mediaKind: mediaKind,
                        onProgress: progressHandler
                    )
                }
            }
            applyLibrarySlimmingResult(result)
        } catch {
            librarySlimmingStatusMessage = "分析失败：\(error.localizedDescription)"
        }
    }

    private func analyzeLibrarySlimmingWithJob(
        analysis: any LibrarySlimmingAnalysisJobPort,
        mode: LibrarySlimmingAnalyzeMode,
        catalogSourceIDs: [UUID]
    ) async {
        librarySlimmingAnalyzeMode = mode
        isAnalyzingLibrarySlimming = true
        hasCompletedLibrarySlimmingScan = false
        librarySlimmingStatusMessage = "正在建立可暂停、可续跑的分析任务…"
        librarySlimmingScanProgress = nil
        selectedLibrarySlimmingMemberIDs = []
        librarySlimmingSelectionAnchorID = nil
        do {
            let workspaceService = service
            let mediaKind = selectedMediaKind
            let mediaNoun = mediaKind == .video ? "视频" : "照片"
            let filter: AssetPageFilter
            let pageSort: AssetPageSort
            let seeds: [UUID]
            switch mode {
            case .catalog:
                filter = AssetPageFilter(
                    sourceIDs: catalogSourceIDs,
                    availabilities: [.available],
                    mediaKinds: [mediaKind]
                )
                pageSort = .newest
                seeds = []
            case .currentFilter:
                filter = currentFilter
                pageSort = sort
                seeds = []
            case .seeds:
                seeds = librarySlimmingSeedAssetIDs
                guard !seeds.isEmpty else {
                    isAnalyzingLibrarySlimming = false
                    librarySlimmingStatusMessage = "请先在图库中选择种子\(mediaNoun)。"
                    return
                }
                let narrowed = hasNarrowedLibrarySlimmingUniverse
                filter = narrowed
                    ? currentFilter
                    : AssetPageFilter(availabilities: [.available], mediaKinds: [mediaKind])
                pageSort = narrowed ? sort : .newest
            }
            let assetIDs = try await Self.offMain {
                try Self.listAllAssetIDs(
                    service: workspaceService,
                    filter: filter,
                    sort: pageSort
                )
            }
            guard !assetIDs.isEmpty else {
                isAnalyzingLibrarySlimming = false
                librarySlimmingStatusMessage = "当前范围没有可分析的\(mediaNoun)。"
                return
            }
            let snapshot = try await Self.offMain {
                try analysis.enqueue(
                    mode: mode,
                    assetIDs: assetIDs,
                    seedAssetIDs: seeds,
                    mediaKind: mediaKind
                )
            }
            await refreshLibrarySlimmingAnalysisJobs()
            applyLibrarySlimmingJobSnapshot(snapshot, forceSelect: true)
            librarySlimmingStatusMessage = "后台自动补全内容指纹与相似度向量…"
            librarySlimmingAnalysisJobState = .running
            startLibrarySlimmingAnalysisAutoRunner()
        } catch {
            isAnalyzingLibrarySlimming = false
            librarySlimmingStatusMessage = "分析失败：\(error.localizedDescription)"
        }
    }

    func pauseLibrarySlimmingAnalysis() async {
        guard let analysis = librarySlimmingAnalysis,
              let jobID = librarySlimmingAnalysisJobID,
              canPauseLibrarySlimmingAnalysis
        else {
            return
        }
        do {
            let snapshot = try await Self.offMain {
                try analysis.pause(jobID: jobID)
            }
            await refreshLibrarySlimmingAnalysisJobs()
            applyLibrarySlimmingJobSnapshot(snapshot, forceSelect: false)
            librarySlimmingStatusMessage = snapshot.state == .paused
                ? "分析已暂停，可稍后继续。"
                : "正在安全暂停…"
        } catch {
            librarySlimmingStatusMessage = "暂停失败：\(error.localizedDescription)"
        }
    }

    func resumeLibrarySlimmingAnalysis() async {
        guard let analysis = librarySlimmingAnalysis,
              let jobID = librarySlimmingAnalysisJobID,
              canResumeLibrarySlimmingAnalysis
        else {
            return
        }
        isAnalyzingLibrarySlimming = true
        do {
            let resumed = try await Self.offMain {
                try analysis.resume(jobID: jobID)
            }
            await refreshLibrarySlimmingAnalysisJobs()
            applyLibrarySlimmingJobSnapshot(resumed, forceSelect: false)
            librarySlimmingStatusMessage = "正在从已保存进度继续并自动补全…"
            librarySlimmingAnalysisJobState = .running
            try await Self.offMain(priority: .utility) {
                try analysis.runPending()
            }
            await refreshLibrarySlimmingAnalysisJobs()
            let snapshot = try await Self.offMain {
                try analysis.snapshot(jobID: jobID)
            }
            applyLibrarySlimmingJobSnapshot(snapshot, forceSelect: false)
            if snapshot.state == .retryableFailed
                || snapshot.state == .pending
                || snapshot.state == .running
            {
                startLibrarySlimmingAnalysisAutoRunner()
            }
        } catch {
            isAnalyzingLibrarySlimming = false
            librarySlimmingStatusMessage = "继续分析失败：\(error.localizedDescription)"
        }
    }

    private func applyLibrarySlimmingJobSnapshot(
        _ snapshot: LibrarySlimmingAnalysisJobSnapshot,
        forceSelect: Bool
    ) {
        let wasAlreadySelected = librarySlimmingAnalysisJobID == snapshot.jobID
        if forceSelect || librarySlimmingAnalysisJobID == nil {
            librarySlimmingAnalysisJobID = snapshot.jobID
        }
        let isSelected = librarySlimmingAnalysisJobID == snapshot.jobID
        if let summary = librarySlimmingAnalysisJobs.first(where: { $0.id == snapshot.jobID }) {
            librarySlimmingAnalyzeMode = summary.mode
        }
        if isSelected {
            librarySlimmingAnalysisJobState = snapshot.state
            librarySlimmingAnalysisControlRequest = snapshot.controlRequest
            let memberCount = librarySlimmingAnalysisJobs
                .first(where: { $0.id == snapshot.jobID })?.memberCount ?? 0
            if let mapped = LibrarySlimmingJobProgressPresentation.scanProgress(
                completed: snapshot.progress.completed,
                progressTotal: snapshot.progress.total ?? 0,
                memberCount: memberCount
            ) {
                librarySlimmingScanProgress = mapped
                if snapshot.state == .running || snapshot.state == .pending {
                    librarySlimmingStatusMessage = mapped.caption
                }
            } else if snapshot.state != .running && snapshot.state != .pending {
                librarySlimmingScanProgress = nil
            }
            if let result = snapshot.result {
                applyLibrarySlimmingResult(
                    result,
                    preserveSelection: !forceSelect && wasAlreadySelected
                )
            } else if forceSelect {
                librarySlimmingClusters = []
                librarySlimmingMemberSourceNames = [:]
                librarySlimmingPendingCount = 0
                hasCompletedLibrarySlimmingScan = false
                selectedLibrarySlimmingClusterID = nil
                selectedLibrarySlimmingMemberIDs = []
                librarySlimmingSelectionAnchorID = nil
                switch snapshot.state {
                case .paused:
                    librarySlimmingStatusMessage = "分析已暂停，可稍后继续。"
                case .retryableFailed:
                    librarySlimmingStatusMessage = "分析会在条件恢复后自动续跑，也可现在继续。"
                case .terminalFailed:
                    librarySlimmingStatusMessage = "分析未完成，请重新发起。"
                case .cancelled:
                    librarySlimmingStatusMessage = "分析已取消。"
                case .pending, .running:
                    break
                case .completed:
                    librarySlimmingStatusMessage = "分析任务已完成。"
                }
            }
        }
        let anyActive = librarySlimmingAnalysisJobs.contains {
            $0.state == .pending || $0.state == .running
        } || snapshot.state == .pending || snapshot.state == .running
        isAnalyzingLibrarySlimming = anyActive
    }

    private func applyLibrarySlimmingResult(
        _ result: LibrarySlimmingScanResult,
        preserveSelection: Bool = false
    ) {
        let previousClusterID = selectedLibrarySlimmingClusterID
        let previousMemberIDs = selectedLibrarySlimmingMemberIDs
        let resolvedClusters = resolveRestoredLibrarySlimmingMembers(result.clusters)
        let filteredClusters = filterLibrarySlimmingClustersForHiddenAssets(resolvedClusters)
        librarySlimmingClusters = filteredClusters.map {
            LibrarySlimmingClusterPresentation($0, mediaKind: selectedMediaKind)
        }
        librarySlimmingPendingCount = result.pendingAnalysisAssetIDs.count
        hasCompletedLibrarySlimmingScan = true
        if preserveSelection,
           let previousClusterID,
           let refreshedCluster = librarySlimmingClusters.first(where: {
               $0.id == previousClusterID
           })
        {
            selectedLibrarySlimmingClusterID = previousClusterID
            selectedLibrarySlimmingMemberIDs = previousMemberIDs.intersection(
                refreshedCluster.memberAssetIDs
            )
            if let anchorID = librarySlimmingSelectionAnchorID,
               !refreshedCluster.memberAssetIDs.contains(anchorID)
            {
                librarySlimmingSelectionAnchorID = nil
            }
        } else {
            selectedLibrarySlimmingClusterID = librarySlimmingClusters.first?.id
            selectedLibrarySlimmingMemberIDs = []
            librarySlimmingSelectionAnchorID = nil
        }
        refreshSelectedLibrarySlimmingMemberSources()
        if filteredClusters.isEmpty, result.pendingAnalysisAssetIDs.isEmpty {
            librarySlimmingStatusMessage = "已分析 \(result.analyzedAssetCount) 张，未发现相同或相似簇。"
        } else if filteredClusters.isEmpty {
            librarySlimmingStatusMessage =
                "已分析 \(result.analyzedAssetCount) 张，暂无成簇结果；\(result.pendingAnalysisAssetIDs.count) 张因不可读取或格式问题待处理。"
        } else if result.pendingAnalysisAssetIDs.isEmpty {
            librarySlimmingStatusMessage =
                "完成：\(filteredClusters.count) 个簇 · 已分析 \(result.analyzedAssetCount) 张。"
        } else {
            librarySlimmingStatusMessage =
                "完成：\(filteredClusters.count) 个簇 · \(result.pendingAnalysisAssetIDs.count) 张因不可读取或格式问题待处理。"
        }
    }

    private func resolveRestoredLibrarySlimmingMembers(
        _ clusters: [SlimmingCluster]
    ) -> [SlimmingCluster] {
        guard let recycle = librarySlimmingRecycle else { return clusters }
        let memberIDs = clusters.flatMap(\.memberAssetIDs)
        guard !memberIDs.isEmpty,
              let replacements = try? recycle.restoredAssetReplacements(from: memberIDs),
              !replacements.isEmpty
        else {
            return clusters
        }
        return clusters.compactMap { cluster in
            var seen = Set<UUID>()
            let members = cluster.memberAssetIDs.compactMap { assetID -> UUID? in
                let resolved = replacements[assetID] ?? assetID
                return seen.insert(resolved).inserted ? resolved : nil
            }
            guard members.count >= 2 else { return nil }
            let representative = replacements[cluster.representativeAssetID]
                ?? cluster.representativeAssetID
            return SlimmingCluster(
                id: cluster.id,
                kind: cluster.kind,
                memberAssetIDs: members,
                representativeAssetID: members.contains(representative)
                    ? representative
                    : members[0],
                score: cluster.score,
                modelIdentity: cluster.modelIdentity
            )
        }
    }

    private func filterLibrarySlimmingClustersForHiddenAssets(
        _ clusters: [SlimmingCluster]
    ) -> [SlimmingCluster] {
        guard let recycle = librarySlimmingRecycle else { return clusters }
        let memberIDs = clusters.flatMap(\.memberAssetIDs)
        guard !memberIDs.isEmpty else { return clusters }
        let hidden = (try? recycle.slimmingHiddenAssetIDs(from: memberIDs)) ?? []
        guard !hidden.isEmpty else { return clusters }
        return filterLibrarySlimmingClustersRemoving(assetIDs: hidden, from: clusters)
    }

    private func filterLibrarySlimmingClustersRemoving(
        assetIDs hidden: Set<UUID>,
        from clusters: [SlimmingCluster]
    ) -> [SlimmingCluster] {
        clusters.compactMap { cluster in
            let remaining = cluster.memberAssetIDs.filter { !hidden.contains($0) }
            guard remaining.count >= 2 else { return nil }
            return SlimmingCluster(
                id: cluster.id,
                kind: cluster.kind,
                memberAssetIDs: remaining,
                representativeAssetID: remaining.contains(cluster.representativeAssetID)
                    ? cluster.representativeAssetID
                    : remaining[0],
                score: cluster.score,
                modelIdentity: cluster.modelIdentity
            )
        }
    }

    private func filterLibrarySlimmingClustersRemoving(
        assetIDs hidden: Set<UUID>,
        from clusters: [LibrarySlimmingClusterPresentation]
    ) -> [LibrarySlimmingClusterPresentation] {
        clusters.compactMap { cluster in
            let remaining = cluster.memberAssetIDs.filter { !hidden.contains($0) }
            guard remaining.count >= 2 else { return nil }
            return LibrarySlimmingClusterPresentation(
                SlimmingCluster(
                    id: cluster.id,
                    kind: cluster.kind,
                    memberAssetIDs: remaining,
                    representativeAssetID: remaining.contains(cluster.representativeAssetID)
                        ? cluster.representativeAssetID
                        : remaining[0],
                    score: cluster.score,
                    modelIdentity: cluster.modelIdentity
                ),
                mediaKind: cluster.mediaKind
            )
        }
    }

    private func refreshSelectedLibrarySlimmingMemberSources() {
        librarySlimmingSourceLoadTask?.cancel()
        guard let cluster = selectedLibrarySlimmingCluster else { return }

        let memberIDs = Set(cluster.memberAssetIDs)
        for item in items where memberIDs.contains(item.assetID) {
            librarySlimmingMemberSourceNames[item.assetID] = item.sourceDisplayName
        }
        let missingAssetIDs = cluster.memberAssetIDs.filter {
            librarySlimmingMemberSourceNames[$0] == nil
        }
        guard !missingAssetIDs.isEmpty else { return }

        let workspaceService = service
        librarySlimmingSourceLoadTask = Task { @MainActor [weak self] in
            for assetID in missingAssetIDs {
                guard !Task.isCancelled else { return }
                let sourceName: String
                do {
                    sourceName = try await Self.offMain(priority: .utility) {
                        try workspaceService.fetchInspectorDetail(assetID: assetID)
                            .sourceDisplayName
                    }
                } catch {
                    sourceName = "来源不可用"
                }
                guard !Task.isCancelled else { return }
                self?.librarySlimmingMemberSourceNames[assetID] = sourceName
            }
        }
    }

    func ensureLibrarySlimmingAnalysisMonitoring() {
        guard librarySlimmingAnalysis != nil else { return }
        guard hasActiveLibrarySlimmingAnalysisJob() else { return }
        isAnalyzingLibrarySlimming = true
        startLibrarySlimmingAnalysisProgressMonitorIfNeeded()
        startLibrarySlimmingAnalysisAutoRunner()
    }

    private func hasActiveLibrarySlimmingAnalysisJob() -> Bool {
        librarySlimmingAnalysisJobs.contains {
            $0.state == .pending || $0.state == .running || $0.state == .retryableFailed
        }
    }

    private func refreshActiveLibrarySlimmingAnalysisProgress() async {
        guard let analysis = librarySlimmingAnalysis else { return }
        if let selectedID = librarySlimmingAnalysisJobID {
            let snapshot = try? await Self.offMain {
                try analysis.snapshot(jobID: selectedID)
            }
            if let snapshot {
                applyLibrarySlimmingJobSnapshot(snapshot, forceSelect: false)
            }
        }
        await refreshLibrarySlimmingAnalysisJobs()
    }

    private func startLibrarySlimmingAnalysisProgressMonitorIfNeeded() {
        guard librarySlimmingAnalysisProgressMonitorTask == nil,
              librarySlimmingAnalysis != nil
        else {
            return
        }
        librarySlimmingAnalysisProgressMonitorTask = Task { @MainActor [weak self] in
            defer { self?.librarySlimmingAnalysisProgressMonitorTask = nil }
            while !Task.isCancelled {
                guard let self else { return }
                guard self.hasActiveLibrarySlimmingAnalysisJob() else { return }
                await self.refreshActiveLibrarySlimmingAnalysisProgress()
                do {
                    try await Task.sleep(for: self.catalogProgressRefreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func startLibrarySlimmingAnalysisAutoRunner() {
        startLibrarySlimmingAnalysisProgressMonitorIfNeeded()
        guard librarySlimmingAnalysisRunnerTask == nil,
              let analysis = librarySlimmingAnalysis
        else {
            return
        }
        librarySlimmingAnalysisRunnerTask = Task { @MainActor [weak self] in
            defer { self?.librarySlimmingAnalysisRunnerTask = nil }
            while !Task.isCancelled {
                guard let self else { return }
                guard self.hasActiveLibrarySlimmingAnalysisJob() else {
                    self.isAnalyzingLibrarySlimming = false
                    return
                }
                _ = try? await Self.offMain(priority: .utility) {
                    try analysis.runPending()
                }
                await self.refreshActiveLibrarySlimmingAnalysisProgress()
                if !self.hasActiveLibrarySlimmingAnalysisJob() {
                    self.isAnalyzingLibrarySlimming = false
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    nonisolated private static func listAllAssetIDs(
        service: any LibraryWorkspacePort,
        filter: AssetPageFilter,
        sort: AssetPageSort
    ) throws -> [UUID] {
        var ids: [UUID] = []
        var cursor: AssetPageCursor?
        repeat {
            let page = try service.fetchAssetPage(filter: filter, sort: sort, cursor: cursor)
            ids.append(contentsOf: page.items.map(\.assetID))
            cursor = page.nextCursor
        } while cursor != nil
        return ids
    }

    func refreshTrainingWorkspace(
        presentation: TrainingWorkspaceRefreshPresentation = .userInitiated
    ) async {
        guard let trainingWorkspace, !isTrainingWorkspaceRefreshInFlight else { return }
        isTrainingWorkspaceRefreshInFlight = true
        if presentation == .userInitiated {
            isRefreshingTrainingWorkspace = true
        }
        defer {
            isTrainingWorkspaceRefreshInFlight = false
            if presentation == .userInitiated {
                isRefreshingTrainingWorkspace = false
            }
        }
        let method = trainingRunMethodFilter
        let mediaKind = selectedMediaKind
        do {
            let snapshot = try await Self.offMain {
                try trainingWorkspace.snapshot(
                    mediaKind: mediaKind,
                    method: method,
                    limit: 200
                )
            }
            trainingRuns = snapshot.runs
            trainingSlots = snapshot.slots
            if let selectedTrainingRunID,
               trainingRuns.contains(where: { $0.id == selectedTrainingRunID })
            {
                return
            }
            selectedTrainingRunID = trainingRuns.first?.id
        } catch {
            trainingRuns = []
            trainingSlots = TrainingRunMethod.allCases.map {
                TrainingWorkspaceSlot(
                    method: $0,
                    isPublished: false,
                    publishedRunID: nil,
                    artifactRef: nil
                )
            }
            selectedTrainingRunID = nil
        }
    }

    func setTrainingRunMethodFilter(_ method: TrainingRunMethod?) async {
        guard trainingRunMethodFilter != method else { return }
        trainingRunMethodFilter = method
        await refreshTrainingWorkspace(presentation: .automatic)
    }

    func setTrainingWorkspaceMediaKind(_ mediaKind: MediaKind) async {
        guard selectedMediaKind != mediaKind else { return }
        selectedMediaKind = mediaKind
        trainingWorkspaceActivity = nil
        selectedTrainingRunID = nil
        await refreshTrainingWorkspace(presentation: .automatic)
    }

    func setLibrarySlimmingWorkspaceMediaKind(_ mediaKind: MediaKind) async {
        guard selectedMediaKind != mediaKind else { return }
        selectedMediaKind = mediaKind
        selectedLibrarySlimmingClusterID = nil
        selectedLibrarySlimmingMemberIDs = []
        librarySlimmingAnalysisJobID = nil
        librarySlimmingClusters = []
        librarySlimmingPendingCount = 0
        await refreshLibrarySlimmingAnalysisJobs()
        await refreshSourceSimilarityIndexStatus()
        await refreshLibrarySlimmingRecycleEntries()
    }

    func selectTrainingRun(_ id: UUID?) {
        guard id == nil || trainingRuns.contains(where: { $0.id == id }) else { return }
        selectedTrainingRunID = id
    }

    var orderedSources: [LibrarySourceSummary] {
        _ = sourceOrderRevision
        return sourceOrderPreferences.ordered(sources)
    }

    var tagGroupSections: [LibraryTagGroupSection] {
        _ = tagGroupCollapseRevision
        _ = tagOrderRevision
        return LibraryTagGroupSection.build(
            groups: tagGroups,
            tags: tags,
            orderPreferences: tagOrderPreferences
        )
    }

    func isTagGroupCollapsed(_ groupID: UUID) -> Bool {
        _ = tagGroupCollapseRevision
        return tagGroupCollapsePreferences.isCollapsed(groupID)
    }

    func toggleTagGroupCollapsed(_ groupID: UUID) {
        tagGroupCollapsePreferences.toggle(groupID)
        tagGroupCollapseRevision &+= 1
    }

    func moveSource(_ sourceID: UUID, before targetID: UUID?) {
        sourceOrderPreferences.move(
            sourceID: sourceID,
            before: targetID,
            in: sources
        )
        sourceOrderRevision &+= 1
    }

    func moveSources(fromOffsets sourceOffsets: IndexSet, toOffset destination: Int) {
        sourceOrderPreferences.move(
            fromOffsets: sourceOffsets,
            toOffset: destination,
            in: sources
        )
        sourceOrderRevision &+= 1
    }

    func moveTags(
        in groupID: UUID,
        fromOffsets sourceOffsets: IndexSet,
        toOffset destination: Int
    ) {
        let groupTags = tags.filter { $0.groupID == groupID }
        tagOrderPreferences.move(
            fromOffsets: sourceOffsets,
            toOffset: destination,
            tags: groupTags,
            in: groupID
        )
        tagOrderRevision &+= 1
    }

    func moveSource(_ sourceID: UUID, to targetID: UUID) {
        let ordered = orderedSources
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = ordered.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex
        else { return }
        let beforeID: UUID?
        if sourceIndex < targetIndex {
            beforeID = ordered.indices.contains(targetIndex + 1)
                ? ordered[targetIndex + 1].id
                : nil
        } else {
            beforeID = targetID
        }
        moveSource(sourceID, before: beforeID)
    }

    func setMaxPendingSuggestionsPerTag(_ count: Int) {
        pendingSuggestionCountPreferences.maxPendingSuggestionsPerTag = count
        maxPendingSuggestionsPerTag = pendingSuggestionCountPreferences.maxPendingSuggestionsPerTag
    }

    func suggestionThresholdDefaults() -> SuggestionThresholdDefaults? {
        guard let suggestionThresholds else { return nil }
        return try? suggestionThresholds.defaults()
    }

    func effectiveSuggestionMinScore(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) -> Double {
        _ = suggestionThresholdEpoch
        guard let suggestionThresholds else { return 0 }
        return (try? suggestionThresholds.effectiveMinScore(tagID: tagID, method: method)) ?? 0
    }

    func suggestionThresholdOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) -> Double? {
        _ = suggestionThresholdEpoch
        guard let suggestionThresholds else { return nil }
        return try? suggestionThresholds.overrideMinScore(tagID: tagID, method: method)
    }

    func suggestionThresholdReferences(
        tagID: UUID
    ) async -> [SuggestionScoreThresholdMethod: SuggestionThresholdReference] {
        guard let suggestionThresholds else { return [:] }
        return (try? await Self.offMain {
            var references:
                [SuggestionScoreThresholdMethod: SuggestionThresholdReference] = [:]
            for method in SuggestionScoreThresholdMethod.allCases {
                if let reference = try suggestionThresholds.referenceSuggestion(
                    tagID: tagID,
                    method: method
                ) {
                    references[method] = reference
                }
            }
            return references
        }) ?? [:]
    }

    func setSuggestionThresholdDefault(
        method: SuggestionScoreThresholdMethod,
        minScore: Double
    ) {
        guard let suggestionThresholds else { return }
        do {
            try suggestionThresholds.setDefault(
                method: method,
                minScore: minScore,
                updatedAtMs: clock.nowMs
            )
            suggestionThresholdEpoch += 1
        } catch {
            notice = .suggestionThresholdUpdateFailed
        }
    }

    func setSuggestionThresholdOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double
    ) {
        guard let suggestionThresholds else { return }
        do {
            try suggestionThresholds.setOverride(
                tagID: tagID,
                method: method,
                minScore: minScore,
                updatedAtMs: clock.nowMs
            )
            suggestionThresholdEpoch += 1
        } catch {
            notice = .suggestionThresholdUpdateFailed
        }
    }

    func clearSuggestionThresholdOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) {
        guard let suggestionThresholds else { return }
        do {
            try suggestionThresholds.clearOverride(tagID: tagID, method: method)
            suggestionThresholdEpoch += 1
        } catch {
            notice = .suggestionThresholdUpdateFailed
        }
    }

    func listSuggestionThresholdOverrides() -> [SuggestionTagThresholdOverrideRow] {
        guard let suggestionThresholds else { return [] }
        return (try? suggestionThresholds.listTagOverrides()) ?? []
    }

    func prunePendingSuggestionsBelowThreshold(
        tagID: UUID,
        displayName: String,
        method: SuggestionScoreThresholdMethod
    ) {
        guard let suggestionThresholds else { return }
        do {
            let minScore = try suggestionThresholds.effectiveMinScore(tagID: tagID, method: method)
            let deleted = try suggestionThresholds.prunePendingBelowThreshold(
                tagID: tagID,
                method: method,
                minScore: minScore
            )
            notice = .suggestionThresholdPruned(
                tagName: displayName,
                methodName: SuggestionScoreThresholdMethodPresentation.displayName(method),
                deletedCount: deleted
            )
            Task { await refreshReviewState() }
        } catch {
            notice = .suggestionThresholdUpdateFailed
        }
    }

    deinit {
        searchDebounceTask?.cancel()
        librarySlimmingSourceLoadTask?.cancel()
        service.stopCatalogSourceMonitoring()
    }

    var isBusy: Bool {
        phase == .loading
            || phase == .scanning
            || isCatalogScanning
            || isRunningLibrarySlimmingIdenticalCleanup
    }

    var supportsPersonalModelRebuild: Bool {
        appPersonalModelRebuilder != nil || localModelSuggestions != nil
    }

    var supportsPersonalAdamWModelRebuild: Bool {
        appPersonalAdamWModelRebuilder != nil
    }

    var supportsSelectedAssetEmbeddingCache: Bool {
        selectedAssetEmbeddingCache != nil
    }

    var canCacheSelectedAssetEmbedding: Bool {
        supportsSelectedAssetEmbeddingCache
            && !selectedAssetIDs.isEmpty
            && !isCachingSelectedAssetEmbedding
    }

    var supportsPersonalLibrarySuggestions: Bool {
        localModelSuggestions != nil || appPersonalSampleSuggester != nil
    }

    var supportsAppPersonalSampleSuggestions: Bool {
        appPersonalSampleSuggester != nil && selectedAssetEmbeddingCache != nil
    }

    var usesAppPersonalSampleSuggestionsPath: Bool {
        supportsAppPersonalSampleSuggestions && localModelSuggestions == nil
    }

    var canGenerateAppPersonalSampleSuggestions: Bool {
        supportsAppPersonalSampleSuggestions
            && !isGeneratingAppPersonalSampleSuggestions
            && !isGeneratingAppPersonalTagLibrarySuggestions
            && !isRebuildingPersonalModel
            && !isRebuildingPersonalAdamWModel
            && !isGeneratingPersonalLibrarySuggestions
            && !isGeneratingStandardLibrarySuggestions
    }

    func canGenerateAppPersonalTagLibrarySuggestions(for overview: SuggestionTagOverview) -> Bool {
        supportsAppPersonalSampleSuggestions
            && appPersonalTagLibrarySuggester != nil
            && overview.canGeneratePersonalModel
            && !isGeneratingAppPersonalSampleSuggestions
            && !isGeneratingAppPersonalTagLibrarySuggestions
            && !isRebuildingPersonalModel
            && !isRebuildingPersonalAdamWModel
            && !isGeneratingPersonalLibrarySuggestions
            && !isGeneratingStandardLibrarySuggestions
    }

    func canGenerateAppPersonalAdamWTagLibrarySuggestions(for overview: SuggestionTagOverview) -> Bool {
        supportsAppPersonalSampleSuggestions
            && appPersonalAdamWTagLibrarySuggester != nil
            && overview.canGeneratePersonalModel
            && !isGeneratingAppPersonalSampleSuggestions
            && !isGeneratingAppPersonalTagLibrarySuggestions
            && !isRebuildingPersonalModel
            && !isRebuildingPersonalAdamWModel
            && !isGeneratingPersonalLibrarySuggestions
            && !isGeneratingStandardLibrarySuggestions
    }

    var supportsStandardLibrarySuggestions: Bool {
        localModelSuggestions != nil
    }

    var isGeneratingPersonalLibrarySuggestions: Bool {
        if isGeneratingAppPersonalSampleSuggestions || isGeneratingAppPersonalTagLibrarySuggestions {
            return true
        }
        switch personalLibrarySuggestionState {
        case .waiting, .running, .paused, .retryableFailure:
            return true
        default:
            return false
        }
    }

    var isGeneratingStandardLibrarySuggestions: Bool {
        switch standardLibrarySuggestionState {
        case .waiting, .running, .paused, .retryableFailure:
            return true
        default:
            return false
        }
    }

    var showsFirstUseGuide: Bool {
        phase == .empty && sources.isEmpty && items.isEmpty && tags.isEmpty
    }

    var canUndoTagMutation: Bool {
        lastTagMutation != nil
    }

    var primarySelectedAssetID: UUID? {
        guard selectedAssetIDs.count == 1 else { return nil }
        return selectedAssetIDs.first
    }

    var singlePhotoNavigation: LibrarySinglePhotoNavigationPresentation? {
        guard isSinglePhotoPresented, let assetID = primarySelectedAssetID else {
            return nil
        }
        if case .tagQueue = reviewMode {
            guard let index = reviewQueueItems.firstIndex(where: {
                if let selectedReviewItemID {
                    return $0.id == selectedReviewItemID
                }
                return $0.assetID == assetID
            }) else {
                return nil
            }
            return LibrarySinglePhotoNavigationPresentation(
                fileName: reviewQueueItems[index].fileName ?? "照片",
                position: index + 1,
                loadedCount: reviewQueueItems.count,
                canMovePrevious: index > 0,
                canMoveNext: index < reviewQueueItems.count - 1 || reviewNextCursor != nil
            )
        }
        guard let index = items.firstIndex(where: { $0.assetID == assetID }) else {
            return nil
        }
        return LibrarySinglePhotoNavigationPresentation(
            fileName: items[index].fileName ?? "照片",
            position: index + 1,
            loadedCount: items.count,
            canMovePrevious: index > 0,
            canMoveNext: index < items.count - 1 || nextCursor != nil
        )
    }

    var hasAssetPropertyFilters: Bool {
        !selectedAvailabilities.isEmpty || !selectedMediaTypes.isEmpty
    }

    var selectedSourceIsPhotos: Bool {
        guard let selectedSourceID else { return false }
        return isPhotosSource(selectedSourceID)
    }

    var browsingTitle: String {
        if reviewMode != nil {
            return "待审核建议"
        }
        if let selectedSourceID,
           let source = sources.first(where: { $0.id == selectedSourceID })
        {
            return source.displayName
        }
        if tagPresence == .untagged {
            return selectedMediaKind == .image ? "无标签照片" : "无标签视频"
        }
        return selectedMediaKind == .image ? "全部照片" : "全部视频"
    }

    var selectionSummaryTitle: String {
        let count = selectedAssetIDs.count
        return "已选择 \(count) \(selectedMediaKind.countingNoun)"
    }

    var selectedPhotosSourceNeedsAuthorization: Bool {
        guard let selectedSourceID else { return false }
        return sources.first(where: { $0.id == selectedSourceID })?.state == .authorizationRequired
    }

    var selectedUnavailablePhotosSource: LibrarySourceSummary? {
        guard let selectedSourceID else { return nil }
        return sources.first(where: {
            $0.id == selectedSourceID && $0.kind == .photos && $0.state == .unavailable
        })
    }

    var canRescan: Bool {
        if let selectedSourceID {
            return sources.first(where: { $0.id == selectedSourceID })?.state == .active
        }
        return sources.contains { $0.state == .active }
    }

    var rescanToolbarTitle: String {
        if let selectedSourceID, isPhotosSource(selectedSourceID) {
            return "立即同步"
        }
        if selectedSourceID == nil,
           sources.count == 1,
           sources.first?.kind == .photos
        {
            return "立即同步"
        }
        return "立即重扫"
    }

    func workspaceCommands(
        matching query: String,
        layout: LibraryWorkspaceLayoutState = LibraryWorkspaceLayoutState()
    ) -> [LibraryWorkspaceCommandItem] {
        let hasSelection = !selectedAssetIDs.isEmpty
        var commands = [
            LibraryWorkspaceCommandItem(
                command: .showAllPhotos,
                title: "前往全部照片",
                systemImage: "photo.on.rectangle.angled",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .showReviewSuggestions,
                title: "前往待审核建议",
                systemImage: "sparkles",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .showActivity,
                title: "显示活动",
                systemImage: "clock.arrow.circlepath",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleSidebar,
                title: layout.isSidebarPresented ? "隐藏侧栏" : "显示侧栏",
                systemImage: "sidebar.left",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleInspector,
                title: layout.isInspectorPresented ? "隐藏检查器" : "显示检查器",
                systemImage: "sidebar.right",
                isEnabled: true
            ),
        ]

        commands.append(contentsOf: sources.map { source in
            LibraryWorkspaceCommandItem(
                command: .showSource(source.id),
                title: "前往来源：\(source.displayName)",
                systemImage: source.kind == .photos ? "photo.on.rectangle" : "externaldrive",
                isEnabled: true
            )
        })
        commands.append(contentsOf: tags.map { tag in
            LibraryWorkspaceCommandItem(
                command: .showTag(tag.id),
                title: "筛选标签：\(tag.displayName)",
                systemImage: "tag",
                isEnabled: true
            )
        })
        for tag in tags {
            commands.append(contentsOf: [
                LibraryWorkspaceCommandItem(
                    command: .acceptTag(tag.id),
                    title: "确认标签：\(tag.displayName)",
                    systemImage: "checkmark.circle",
                    isEnabled: hasSelection
                ),
                LibraryWorkspaceCommandItem(
                    command: .rejectTag(tag.id),
                    title: "拒绝标签：\(tag.displayName)",
                    systemImage: "xmark.circle",
                    isEnabled: hasSelection
                ),
                LibraryWorkspaceCommandItem(
                    command: .clearTagDecision(tag.id),
                    title: "清除标签决定：\(tag.displayName)",
                    systemImage: "minus.circle",
                    isEnabled: hasSelection
                ),
            ])
        }
        commands.append(contentsOf: [
            LibraryWorkspaceCommandItem(
                command: .createTag,
                title: "新建标签",
                systemImage: "tag.badge.plus",
                isEnabled: hasSelection
            ),
            LibraryWorkspaceCommandItem(
                command: .connectFolder,
                title: "连接文件夹",
                systemImage: "folder.badge.plus",
                isEnabled: !isBusy
            ),
            LibraryWorkspaceCommandItem(
                command: .rescanCurrentSource,
                title: "重扫当前来源",
                systemImage: "arrow.clockwise",
                isEnabled: !isBusy && canRescan
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleSinglePhoto,
                title: isSinglePhotoPresented ? "返回照片网格" : "切换单图查看",
                systemImage: isSinglePhotoPresented ? "square.grid.2x2" : "photo",
                isEnabled: primarySelectedAssetID != nil
            ),
            LibraryWorkspaceCommandItem(
                command: .showKeyboardShortcuts,
                title: "显示快捷键",
                systemImage: "keyboard",
                isEnabled: true
            ),
        ])

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    func isPhotosSource(_ sourceID: UUID) -> Bool {
        sources.first(where: { $0.id == sourceID })?.kind == .photos
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try service.startCatalogSourceMonitoring { [weak self] in
                Task { @MainActor [weak self] in
                    self?.startCatalogReconcileRunnerIfNeeded()
                }
            }
        } catch {
            notice = .backgroundScanFailed
        }
        await reload(runPendingJobs: false)
        await runLibrarySlimmingMaintenance()
        await restoreDefaultSourceAuthorizations()
        for source in sources where source.kind == .photos && source.state == .active {
            await ensurePhotosLibraryIndexed(sourceID: source.id)
        }
        if !isCatalogScanning {
            startCatalogReconcileRunnerIfNeeded()
        }
        startPersonalizationRunnerIfNeeded()
        startIdleThumbnailPrewarmIfNeeded()
    }

    var canRefreshLibrarySlimmingCatalog: Bool {
        !isCatalogScanning
            && !isMutatingLibrarySlimmingRecycle
            && sources.contains { $0.state == .active }
    }

    /// Catalog source events are still recorded while this workspace is open,
    /// but they must not launch repeated full-source reconciliation around each
    /// user-confirmed recycle operation.
    func setLibrarySlimmingWorkspaceActive(_ isActive: Bool) {
        guard isLibrarySlimmingWorkspaceActive != isActive else { return }
        isLibrarySlimmingWorkspaceActive = isActive
        guard !isActive, librarySlimmingCatalogRefreshPendingAfterExit else { return }

        let requestedSourceIDs = librarySlimmingCatalogRefreshSourceIDs
        librarySlimmingCatalogRefreshPendingAfterExit = false
        librarySlimmingCatalogRefreshSourceIDs = []
        Task { @MainActor [weak self] in
            await self?.refreshLibrarySlimmingCatalog(
                preferredSourceIDs: requestedSourceIDs,
                reportsStatus: false
            )
        }
    }

    /// Explicit user refresh is the only catalog reconcile allowed to start
    /// while the library-slimming workspace remains visible.
    func refreshLibrarySlimmingCatalog() async {
        await refreshLibrarySlimmingCatalog(
            preferredSourceIDs: [],
            reportsStatus: true
        )
    }

    private func refreshLibrarySlimmingCatalog(
        preferredSourceIDs: Set<UUID>,
        reportsStatus: Bool
    ) async {
        let activeSourceIDs = Set(
            sources.lazy
                .filter { $0.state == .active }
                .map(\.id)
        )
        guard !activeSourceIDs.isEmpty else {
            if reportsStatus {
                librarySlimmingStatusMessage = "当前没有可刷新的照片来源"
            }
            return
        }
        let preferredActiveSourceIDs = preferredSourceIDs.intersection(activeSourceIDs)
        let requestedSourceIDs = preferredActiveSourceIDs.isEmpty
            ? activeSourceIDs
            : preferredActiveSourceIDs
        let service = service
        do {
            try await Self.offMain(priority: .utility) {
                try service.enqueueReconcile(
                    sourceIDs: requestedSourceIDs.sorted {
                        $0.uuidString < $1.uuidString
                    }
                )
            }
            librarySlimmingCatalogRefreshPendingAfterExit = false
            librarySlimmingCatalogRefreshSourceIDs = []
            if reportsStatus {
                librarySlimmingStatusMessage = "正在刷新照片来源…"
                reportsLibrarySlimmingCatalogRefreshCompletion = true
            }
            startCatalogReconcileRunnerIfNeeded(allowInLibrarySlimming: true)
        } catch {
            if reportsStatus {
                librarySlimmingStatusMessage = "刷新来源失败：\(error.localizedDescription)"
            } else {
                notice = .backgroundScanFailed
            }
        }
    }

    private func noteLibrarySlimmingCatalogMutation(assetIDs: Set<UUID>) {
        guard !assetIDs.isEmpty else { return }
        librarySlimmingCatalogRefreshPendingAfterExit = true
        librarySlimmingCatalogRefreshSourceIDs.formUnion(
            librarySlimmingRecycleEntries.lazy
                .filter { assetIDs.contains($0.assetID) }
                .map(\.sourceID)
        )
    }

    func applicationDidBecomeActive() async {
        await runLibrarySlimmingMaintenance()
    }

    private func runLibrarySlimmingMaintenance() async {
        guard let recycle = librarySlimmingRecycle,
              !isLibrarySlimmingMaintenanceRunning
        else {
            return
        }
        isLibrarySlimmingMaintenanceRunning = true
        defer { isLibrarySlimmingMaintenanceRunning = false }

        _ = try? await Self.offMain(priority: .utility) {
            try recycle.recoverInterruptedOperations()
        }
        _ = try? await Self.offMain(priority: .utility) {
            try recycle.enqueuePurgeExpired()
        }
        let service = service
        _ = try? await Self.offMain(priority: .utility) {
            try service.runPendingLibrarySlimmingJobs()
        }
        if librarySlimmingAnalysis != nil {
            await refreshLibrarySlimmingAnalysisJobs()
            if let selected = librarySlimmingAnalysisJobID {
                await loadLibrarySlimmingAnalysisJob(selected, forceSelect: false)
            } else if let latest = librarySlimmingAnalysisJobs.first {
                await loadLibrarySlimmingAnalysisJob(latest.id)
            }
            let hasActive = librarySlimmingAnalysisJobs.contains {
                $0.state == .pending || $0.state == .running || $0.state == .retryableFailed
            }
            if hasActive {
                startLibrarySlimmingAnalysisAutoRunner()
            }
        }
        _ = try? await Self.offMain(priority: .utility) {
            try recycle.enqueuePurgeExpired()
        }
        if librarySlimmingWorkspaceTab == .recycleBin {
            await refreshLibrarySlimmingRecycleEntries()
        }
    }

    func setIdleThumbnailPrewarmEnabled(_ enabled: Bool) {
        idleThumbnailPrewarmPreferenceStore.isEnabled = enabled
        isIdleThumbnailPrewarmEnabled = enabled
        idleThumbnailPrewarmController?.isEnabled = enabled
    }

    func noteUserInteractionForIdlePrewarm() {
        idleThumbnailPrewarmController?.noteUserInteraction()
    }

    func evaluateIdleThumbnailPrewarmForTesting() {
        idleThumbnailPrewarmController?.evaluateIdleState()
    }

    var isIdleThumbnailPrewarmingForTesting: Bool {
        idleThumbnailPrewarmController?.isPrewarming == true
    }

    private func startIdleThumbnailPrewarmIfNeeded() {
        guard idleThumbnailPrewarmController == nil else { return }
        let controller = IdleThumbnailPrewarmController(
            preferenceStore: idleThumbnailPrewarmPreferenceStore,
            clock: idlePrewarmClock,
            idleThresholdSeconds: idlePrewarmThresholdSeconds,
            monitorTickSeconds: idlePrewarmMonitorTickSeconds,
            installEventMonitor: idlePrewarmInstallEventMonitor
        ) { [weak self] generation in
            await self?.runIdleThumbnailPrewarm(generation: generation)
        }
        idleThumbnailPrewarmController = controller
        isIdleThumbnailPrewarmEnabled = idleThumbnailPrewarmPreferenceStore.isEnabled
        controller.start()
    }

    private func runIdleThumbnailPrewarm(generation: Int) async {
        let gridItems = items
        for item in gridItems {
            if Task.isCancelled { return }
            guard idlePrewarmIsCurrentGeneration(generation) else { return }
            let assetID = item.assetID
            if cachedThumbnailData(for: assetID) == nil {
                await warmGridThumbnailForIdlePrewarm(assetID: assetID, generation: generation)
                guard idlePrewarmIsCurrentGeneration(generation), !Task.isCancelled else { return }
            }
            await warmFeaturePrintForIdlePrewarm(assetID: assetID, generation: generation)
            guard idlePrewarmIsCurrentGeneration(generation), !Task.isCancelled else { return }
            await warmEmbeddingForIdlePrewarm(
                assetID: assetID,
                contentRevision: item.contentRevision,
                generation: generation
            )
        }
    }

    private func idlePrewarmIsCurrentGeneration(_ generation: Int) -> Bool {
        idleThumbnailPrewarmController?.currentPrewarmGeneration == generation
    }

    private func warmGridThumbnailForIdlePrewarm(assetID: UUID, generation: Int) async {
        guard cachedThumbnailData(for: assetID) == nil else { return }
        guard idlePrewarmIsCurrentGeneration(generation) else { return }
        let service = service
        do {
            try Task.checkCancellation()
            let data = try await service.loadThumbnail(assetID: assetID)
            guard idlePrewarmIsCurrentGeneration(generation) else { return }
            rememberThumbnailData(data, for: assetID)
        } catch is CancellationError {
            return
        } catch {
            // Best-effort; browsing remains available.
        }
    }

    private func warmFeaturePrintForIdlePrewarm(assetID: UUID, generation: Int) async {
        guard let loader = idleFeaturePrintCache else { return }
        guard !idlePrewarmSkippedAssetIDs.contains(assetID) else { return }
        guard idlePrewarmIsCurrentGeneration(generation) else { return }
        do {
            try Task.checkCancellation()
            _ = try await Self.cancellableOffMain(priority: .utility) {
                try loader.loadOrGenerateSync(assetID: assetID)
            }
            guard idlePrewarmIsCurrentGeneration(generation) else { return }
        } catch is CancellationError {
            return
        } catch {
            idlePrewarmSkippedAssetIDs.insert(assetID)
        }
    }

    private func warmEmbeddingForIdlePrewarm(
        assetID: UUID,
        contentRevision: Int,
        generation: Int
    ) async {
        guard contentRevision > 0,
              !idlePrewarmEmbeddingUnavailable,
              let cache = selectedAssetEmbeddingCache
        else { return }
        guard !idlePrewarmSkippedAssetIDs.contains(assetID) else { return }
        guard idlePrewarmIsCurrentGeneration(generation) else { return }
        let service = service
        do {
            try Task.checkCancellation()
            _ = try await cache.cacheSelectedAsset(
                assetID: assetID,
                contentRevision: contentRevision,
                imageData: {
                    try Task.checkCancellation()
                    guard !Task.isCancelled else { throw CancellationError() }
                    return try await service.loadPreview(assetID: assetID)
                }
            )
            guard idlePrewarmIsCurrentGeneration(generation) else { return }
        } catch is CancellationError {
            return
        } catch AppSelectedAssetEmbeddingCacheError.modelUnavailable {
            idlePrewarmEmbeddingUnavailable = true
        } catch PhotosLibraryError.cloudOnly {
            idlePrewarmSkippedAssetIDs.insert(assetID)
        } catch {
            idlePrewarmSkippedAssetIDs.insert(assetID)
        }
    }

    var isPrewarmingSourceThumbnails: Bool {
        sourceThumbnailPrewarmProgress != nil
    }

    func prewarmSourceThumbnails(sourceID: UUID) {
        guard !isPrewarmingSourceThumbnails else { return }
        guard canStartSourceThumbnailPrewarm(sourceID: sourceID) else { return }
        sourceThumbnailPrewarmTask = Task(priority: .utility) { [weak self] in
            await self?.runSourceThumbnailPrewarm(sourceID: sourceID)
        }
    }

    func cancelSourceThumbnailPrewarm() {
        guard let progress = sourceThumbnailPrewarmProgress else { return }
        sourceThumbnailPrewarmGeneration += 1
        sourceThumbnailPrewarmTask?.cancel()
        sourceThumbnailPrewarmTask = nil
        sourceThumbnailPrewarmProgress = nil
        notice = .sourceThumbnailPrewarmCancelled(
            sourceDisplayName: progress.sourceDisplayName,
            completed: progress.completed,
            total: progress.total
        )
    }

    private func canStartSourceThumbnailPrewarm(sourceID: UUID) -> Bool {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return false }
        guard source.state == .active || source.state == .unavailable else { return false }

        noteUserInteractionForIdlePrewarm()
        notice = nil
        sourceThumbnailPrewarmGeneration += 1
        sourceThumbnailPrewarmProgress = SourceThumbnailPrewarmProgress(
            sourceID: sourceID,
            sourceDisplayName: source.displayName,
            completed: 0,
            total: 0,
            warmed: 0,
            failed: 0
        )
        return true
    }

    private func runSourceThumbnailPrewarm(sourceID: UUID) async {
        let generation = sourceThumbnailPrewarmGeneration
        let sourceDisplayName = sourceThumbnailPrewarmProgress?.sourceDisplayName
            ?? sources.first(where: { $0.id == sourceID })?.displayName
            ?? "来源"
        let service = service
        defer {
            if sourceThumbnailPrewarmGeneration == generation {
                sourceThumbnailPrewarmTask = nil
                sourceThumbnailPrewarmProgress = nil
            }
        }

        var assetIDs: [UUID] = []
        do {
            var cursor: AssetPageCursor?
            // Match the workspace "no search" filter shape (empty string, not nil).
            let filter = AssetPageFilter(sourceIDs: [sourceID], searchText: "")
            var pageCount = 0
            repeat {
                guard sourceThumbnailPrewarmGeneration == generation, !Task.isCancelled else { return }
                pageCount += 1
                // Safety cap: production pages are 100 items; this bounds pathological cursors.
                guard pageCount <= 100_000 else { break }
                let page = try service.fetchAssetPage(
                    filter: filter,
                    sort: .newest,
                    cursor: cursor
                )
                // Fail closed on a stuck cursor so a bad page implementation cannot spin forever.
                if page.items.isEmpty {
                    break
                }
                assetIDs.append(contentsOf: page.items.map(\.assetID))
                let next = page.nextCursor
                if next == cursor {
                    break
                }
                cursor = next
            } while cursor != nil
        } catch {
            guard sourceThumbnailPrewarmGeneration == generation else { return }
            notice = .sourceThumbnailPrewarmFailed
            return
        }

        guard sourceThumbnailPrewarmGeneration == generation else { return }
        sourceThumbnailPrewarmProgress = SourceThumbnailPrewarmProgress(
            sourceID: sourceID,
            sourceDisplayName: sourceDisplayName,
            completed: 0,
            total: assetIDs.count,
            warmed: 0,
            failed: 0
        )

        var warmed = 0
        var failed = 0
        for (index, assetID) in assetIDs.enumerated() {
            guard sourceThumbnailPrewarmGeneration == generation, !Task.isCancelled else { return }
            do {
                try Task.checkCancellation()
                let data = try await service.loadThumbnail(assetID: assetID)
                guard sourceThumbnailPrewarmGeneration == generation else { return }
                rememberThumbnailData(data, for: assetID)
                warmed += 1
            } catch is CancellationError {
                return
            } catch {
                guard sourceThumbnailPrewarmGeneration == generation else { return }
                failed += 1
            }
            guard sourceThumbnailPrewarmGeneration == generation else { return }
            sourceThumbnailPrewarmProgress = SourceThumbnailPrewarmProgress(
                sourceID: sourceID,
                sourceDisplayName: sourceDisplayName,
                completed: index + 1,
                total: assetIDs.count,
                warmed: warmed,
                failed: failed
            )
        }

        guard sourceThumbnailPrewarmGeneration == generation else { return }
        notice = .sourceThumbnailPrewarmCompleted(
            sourceDisplayName: sourceDisplayName,
            warmed: warmed,
            failed: failed,
            total: assetIDs.count
        )
    }

    func exportPortableUserData() async {
        guard !isExportingPortableData else { return }
        notice = nil
        guard let parentDirectoryURL = service.choosePortableExportDirectory() else { return }

        isExportingPortableData = true
        defer { isExportingPortableData = false }
        let service = service
        do {
            let result = try await Self.offMain {
                try service.exportPortableUserData(to: parentDirectoryURL)
            }
            notice = .portableExportCompleted(
                bundleName: result.bundleURL.lastPathComponent,
                recordCount: result.totalRecordCount
            )
        } catch PortableCatalogExportError.destinationOverlapsSource {
            notice = .portableExportDestinationOverlapsSource
        } catch PortableCatalogExportError.destinationIsolationIndeterminate {
            notice = .portableExportIsolationIndeterminate
        } catch {
            notice = .portableExportFailed
        }
    }

    func refreshPreviewCacheUsage() async {
        let service = service
        do {
            let usage = try await Self.offMain {
                (
                    preview: try service.fetchPreviewCacheUsage(),
                    photosOriginals: try service.fetchPhotosOriginalStorageUsage()
                )
            }
            previewCacheUsage = usage.preview
            photosOriginalStorageUsage = usage.photosOriginals
            appStorageLocation = service.fetchAppStorageLocation()
        } catch {
            notice = .previewCacheActionFailed
        }
    }

    func chooseExternalAppStorageLocation() async {
        guard !isChoosingAppStorageLocation else { return }
        isChoosingAppStorageLocation = true
        notice = nil
        defer { isChoosingAppStorageLocation = false }

        do {
            switch try await service.chooseExternalAppStorageLocation() {
            case .cancelled:
                return
            case let .restartRequired(status):
                appStorageLocation = status
                notice = .appStorageLocationRequiresRestart
            }
        } catch {
            notice = .appStorageLocationActionFailed
        }
    }

    func refreshLocalModelServiceHealth() async {
        guard let localModelSuggestions else {
            localModelServiceHealthState = .unavailable
            return
        }
        localModelServiceHealthState = .checking
        do {
            switch try await localModelSuggestions.client.serviceHealth() {
            case let .ready(serviceVersion, provider):
                localModelServiceHealthState = .ready(
                    serviceVersion: serviceVersion,
                    provider: provider
                )
            case let .degraded(serviceVersion):
                localModelServiceHealthState = .degraded(
                    serviceVersion: serviceVersion
                )
            }
        } catch {
            localModelServiceHealthState = .unavailable
        }
    }

    func clearPreviewCache() async {
        guard !isClearingPreviewCache else { return }
        isClearingPreviewCache = true
        notice = nil
        defer { isClearingPreviewCache = false }
        let service = service
        do {
            let result = try await service.clearPreviewCache()
            previewCacheUsage = try await Self.offMain {
                try service.fetchPreviewCacheUsage()
            }
            notice = .previewCacheCleared(
                removedEntries: result.removedEntries,
                partialReclaim: result.partialReclaim
            )
        } catch {
            notice = .previewCacheActionFailed
            await refreshPreviewCacheUsage()
        }
    }

    var canClearPhotosOriginalStorage: Bool {
        photosOriginalStorageUsage.entryCount > 0
            && !isAnalyzingLibrarySlimming
            && !isClearingPhotosOriginalStorage
    }

    func clearPhotosOriginalStorage() async {
        guard canClearPhotosOriginalStorage else { return }
        isClearingPhotosOriginalStorage = true
        notice = nil
        defer { isClearingPhotosOriginalStorage = false }
        let service = service
        do {
            let result = try await Self.offMain {
                try service.clearPhotosOriginalStorage()
            }
            photosOriginalStorageUsage = try await Self.offMain {
                try service.fetchPhotosOriginalStorageUsage()
            }
            notice = .photosOriginalStorageCleared(
                removedEntries: result.removedEntries,
                partialReclaim: result.partialReclaim
            )
        } catch {
            notice = .photosOriginalStorageActionFailed
            do {
                photosOriginalStorageUsage = try await Self.offMain {
                    try service.fetchPhotosOriginalStorageUsage()
                }
            } catch {
                // Preserve the last known usage when refresh also fails.
            }
        }
    }

    func refreshJobActivity() async {
        let service = service
        do {
            jobActivityItems = try await Self.offMain {
                try service.fetchJobActivity()
            }
        } catch {
            notice = .jobActivityActionFailed
        }
    }

    func isApplyingJobActivityAction(_ jobID: UUID) -> Bool {
        jobActivityActionInFlightIDs.contains(jobID)
    }

    func applyJobActivityAction(_ action: JobActivityAction, to jobID: UUID) async {
        guard let item = jobActivityItems.first(where: { $0.id == jobID }),
              item.availableActions.contains(action),
              !jobActivityActionInFlightIDs.contains(jobID)
        else {
            return
        }
        jobActivityActionInFlightIDs.insert(jobID)
        notice = nil
        defer { jobActivityActionInFlightIDs.remove(jobID) }
        let service = service
        do {
            jobActivityItems = try await Self.offMain {
                try service.applyJobActivityAction(action, jobID: jobID)
                return try service.fetchJobActivity()
            }
            if action == .resume {
                startPersonalizationRunnerIfNeeded()
            }
            await refreshReviewState()
        } catch {
            if let refreshed = try? await Self.offMain({ try service.fetchJobActivity() }) {
                jobActivityItems = refreshed
            }
            await refreshReviewState()
            notice = .jobActivityActionFailed
        }
    }

    func connectFolder() async {
        guard !isBusy else { return }
        phase = .scanning
        do {
            switch try await service.connectFolder() {
            case .cancelled:
                await reload(runPendingJobs: false)
            case .connected:
                await reload(runPendingJobs: true)
            }
        } catch {
            phase = .failed(.connectionFailed)
        }
    }

    func connectPhotos() async {
        guard !isBusy else { return }
        notice = nil
        do {
            let outcome = try await service.connectPhotos()
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            switch outcome {
            case .connected:
                phase = .scanning
                await loadFirstPage()
                startCatalogReconcileRunnerIfNeeded()
            case .alreadyConnected:
                phase = sources.isEmpty ? .empty : .content
                notice = .photosAlreadyConnected
            }
        } catch PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted {
            let service = service
            if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                sources = refreshed
            }
            phase = sources.isEmpty ? .empty : .content
            notice = .photosAuthorizationRequired
        } catch {
            phase = .failed(.connectionFailed)
        }
    }

    func rebindPhotos(from unavailableSourceID: UUID) async {
        guard !isBusy,
              sources.contains(where: {
                  $0.id == unavailableSourceID && $0.kind == .photos && $0.state == .unavailable
              })
        else {
            return
        }
        let previousPhase = phase
        notice = nil
        phase = .scanning
        do {
            _ = try await service.rebindPhotos(unavailableSourceID: unavailableSourceID)
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
            startCatalogReconcileRunnerIfNeeded()
        } catch PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted {
            phase = previousPhase
            notice = .photosAuthorizationRequired
        } catch {
            phase = previousPhase
            notice = .sourceActionFailed
        }
    }

    func reauthorizeSource(_ sourceID: UUID) async {
        guard !isBusy else { return }
        let previousPhase = phase
        notice = nil
        do {
            if sources.first(where: { $0.id == sourceID })?.kind == .photos {
                try await service.reactivatePhotosLibrary(sourceID: sourceID)
                let service = service
                sources = try await Self.offMain { try service.fetchSources() }
                await loadFirstPage()
                startCatalogReconcileRunnerIfNeeded()
                notice = .photosSyncQueued
                return
            }
            switch try await service.reauthorizeFolder(sourceID: sourceID) {
            case .cancelled:
                return
            case .reauthorized:
                break
            }

            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
            startCatalogReconcileRunnerIfNeeded()
        } catch {
            phase = previousPhase
            notice = .sourceActionFailed
        }
    }

    func refreshFolderMutationAuthorization(_ sourceID: UUID) async {
        guard !isBusy,
              sources.contains(where: {
                  $0.id == sourceID && $0.kind == .folder && $0.state == .active
              }),
              let mutationAuthorization = librarySlimmingMutationAuthorization
        else { return }
        do {
            switch try await mutationAuthorization.authorizeMutation(sourceID: sourceID) {
            case .authorized:
                librarySlimmingStatusMessage = "已更新来源回收权限，可以重新执行删除或恢复。"
            case .cancelled:
                return
            }
        } catch {
            notice = .sourceActionFailed
        }
    }

    func disableSource(_ sourceID: UUID) async {
        guard !isBusy else { return }
        notice = nil
        do {
            _ = try await service.disableFolderSource(sourceID: sourceID)
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
        } catch {
            notice = .sourceActionFailed
        }
    }

    func rescan() async {
        guard !isBusy, !sources.isEmpty else { return }
        if let selectedSourceID, isPhotosSource(selectedSourceID) {
            await syncPhotosLibrary(sourceID: selectedSourceID)
            return
        }
        if selectedSourceID == nil,
           sources.count == 1,
           let photosSource = sources.first,
           photosSource.kind == .photos,
           photosSource.state == .active
        {
            await syncPhotosLibrary(sourceID: photosSource.id)
            return
        }
        let service = service
        let sourceIDs = selectedSourceID.map { [$0] } ?? sources.map(\.id)
        do {
            try await Self.offMain {
                try service.enqueueReconcile(sourceIDs: sourceIDs)
            }
        } catch {
            if items.isEmpty {
                phase = .failed(.scanFailed)
            } else {
                notice = .backgroundScanFailed
            }
            return
        }
        startCatalogReconcileRunnerIfNeeded()
    }

    func syncPhotosLibrary(sourceID: UUID) async {
        guard !isBusy else { return }
        notice = nil
        do {
            try await enqueuePhotosLibrarySync(sourceID: sourceID)
            notice = .photosSyncQueued
        } catch {
            notice = .sourceActionFailed
        }
    }

    private func enqueuePhotosLibrarySync(sourceID: UUID) async throws {
        let service = service
        try await service.syncPhotosLibrary(sourceID: sourceID)
        startCatalogReconcileRunnerIfNeeded()
    }

    /// Startup-only integrity check: enqueue full repair when the catalog is
    /// clearly incomplete, otherwise a quiet incremental sync only when the
    /// source is not already reconcile-clean. Source switching must not re-run
    /// this — that caused visible grid flicker.
    private func ensurePhotosLibraryIndexed(sourceID: UUID) async {
        let service = service
        do {
            let needsFullRepair = try await Self.offMain {
                let libraryCount = try service.photosLibrarySupportedImageCount()
                let catalogCount = try service.photosCatalogAssetCount(sourceID: sourceID)
                guard libraryCount > 0 else { return false }
                return catalogCount * 100 < libraryCount * 95
            }
            var enqueuedWork = false
            if needsFullRepair {
                try await service.requestPhotosFullRepair(sourceID: sourceID)
                enqueuedWork = true
            } else {
                let isClean = try await Self.offMain {
                    try service.sourceIsReconcileClean(sourceID: sourceID)
                }
                if !isClean {
                    try await service.syncPhotosLibrary(sourceID: sourceID)
                    enqueuedWork = true
                }
            }
            if enqueuedWork {
                startCatalogReconcileRunnerIfNeeded()
            }
        } catch {
            // Startup self-heal stays silent; toolbar actions still surface errors.
        }
    }

    func requestPhotosFullRepair(sourceID: UUID) async {
        guard !isBusy else { return }
        notice = nil
        let service = service
        do {
            try await service.requestPhotosFullRepair(sourceID: sourceID)
            startCatalogReconcileRunnerIfNeeded()
            notice = .photosFullRepairQueued
        } catch {
            notice = .sourceActionFailed
        }
    }

    var hasActiveTagFilters: Bool {
        !selectedTagFilterIDs.isEmpty || !excludedTagFilterIDs.isEmpty
    }

    func tagFilterSummaryText() -> String? {
        Self.makeTagFilterSummaryText(
            tags: tags,
            includedTagIDs: selectedTagFilterIDs,
            excludedTagIDs: excludedTagFilterIDs,
            matchMode: tagMatchMode
        )
    }

    static func makeTagFilterSummaryText(
        tags: [TagListItem],
        includedTagIDs: Set<UUID>,
        excludedTagIDs: Set<UUID>,
        matchMode: TagMatchMode
    ) -> String? {
        let tagNames = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.displayName) })
        let includedNames = includedTagIDs.compactMap { tagNames[$0] }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let excludedNames = excludedTagIDs.compactMap { tagNames[$0] }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        guard !includedNames.isEmpty || !excludedNames.isEmpty else { return nil }

        var parts: [String] = []
        if !includedNames.isEmpty {
            let joiner = matchMode == .all ? " 且 " : " 或 "
            parts.append(includedNames.joined(separator: joiner))
        }
        if !excludedNames.isEmpty {
            parts.append("排除 " + excludedNames.joined(separator: "、"))
        }
        return parts.joined(separator: " · ")
    }

    private func publishTagMutationNotice(
        count: Int,
        tagDisplayName: String,
        action: LibraryTagMutationFeedbackKind
    ) {
        guard count > 0 else { return }
        notice = .tagBatchMutationApplied(
            count: count,
            tagDisplayName: tagDisplayName,
            action: action
        )
    }

    private func tagDisplayName(for tagID: UUID) -> String {
        tags.first(where: { $0.id == tagID })?.displayName ?? "标签"
    }

    private static func tagMutationFeedbackKind(
        for action: LibraryTagDecisionAction
    ) -> LibraryTagMutationFeedbackKind {
        switch action {
        case .accept: .accepted
        case .reject: .rejected
        case .clear: .cleared
        }
    }

    func selectSource(_ sourceID: UUID?) async {
        guard selectedSourceID != sourceID else { return }
        selectedSourceID = sourceID
        // Navigation only swaps the visible filter. Photos integrity / sync is
        // handled once at start() so switching sources stays flicker-free.
        await loadFirstPage(remountGrid: true)
        await refreshSourceSimilarityIndexStatus()
    }

    func beginBrowsingNavigation() -> UUID {
        let requestID = UUID()
        browsingNavigationRequestID = requestID
        // Invalidate a page query started by the prior sidebar selection even
        // before the newest navigation task gets scheduled on the main actor.
        assetPageRequestID = UUID()
        thumbnailLoadEpoch &+= 1
        return requestID
    }

    func navigate(
        to destination: LibraryBrowsingDestination,
        requestID: UUID
    ) async {
        guard browsingNavigationRequestID == requestID else { return }

        switch destination {
        case .reviewSuggestions:
            cancelPendingLibrarySlimmingSeedAnalyze()
            // Re-check before mutating: a newer sidebar selection may have
            // invalidated this request between the top guard and this case.
            guard browsingNavigationRequestID == requestID else { return }
            await enterReviewOverview()
            guard browsingNavigationRequestID == requestID else { return }
        case .trainingWorkspace:
            cancelPendingLibrarySlimmingSeedAnalyze()
            clearReviewModeState()
            guard browsingNavigationRequestID == requestID else { return }
            await refreshTrainingWorkspace(presentation: .automatic)
        case .librarySlimming:
            clearReviewModeState()
            guard browsingNavigationRequestID == requestID else { return }
            await refreshLibrarySlimmingAnalysisJobs()
            if librarySlimmingAnalysisJobID == nil, let latest = librarySlimmingAnalysisJobs.first {
                await loadLibrarySlimmingAnalysisJob(latest.id)
            }
            await consumePendingLibrarySlimmingSeedAnalyzeIfNeeded(
                navigationRequestID: requestID
            )

        case .all, .untagged, .source:
            cancelPendingLibrarySlimmingSeedAnalyze()
            clearReviewModeState()
            applyGalleryBrowsingFilters(for: destination)
            await loadFirstPage(remountGrid: true)
            guard browsingNavigationRequestID == requestID else { return }
            await refreshReviewState()
        }
    }

    func loadMoreIfNeeded(currentAssetID: UUID) async {
        guard currentAssetID == items.last?.assetID,
              let cursor = nextCursor,
              !isLoadingMore
        else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let service = service
        let filter = currentFilter
        let sort = sort
        let requestID = assetPageRequestID
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: cursor)
            }
            guard assetPageRequestID == requestID else { return }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            guard assetPageRequestID == requestID else { return }
            phase = .failed(.catalogFailed)
        }
    }

    /// Soft-restores existing source authorizations (Photos TCC + folder bookmarks)
    /// without presenting pickers for every source.
    private func restoreDefaultSourceAuthorizations() async {
        do {
            try await service.restoreDefaultSourceAuthorizations()
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
        } catch {
            // Keep previous source list; user can still reauthorize manually.
        }
    }

    func thumbnailData(assetID: UUID) async -> Data? {
        if let cached = cachedThumbnailData(for: assetID) {
            return cached
        }
        if case let .loaded(data) = await loadThumbnailResult(assetID: assetID) {
            rememberThumbnailData(data, for: assetID)
            return data
        }
        return nil
    }

    func cachedThumbnailData(for assetID: UUID) -> Data? {
        thumbnailDataCache[assetID]
    }

    func thumbnailCacheVersion(for assetID: UUID) -> Int {
        thumbnailCacheVersions[assetID, default: 0]
    }

    func rememberThumbnailData(_ data: Data, for assetID: UUID) {
        guard !data.isEmpty else { return }
        if thumbnailDataCache[assetID] == data { return }
        thumbnailDataCache[assetID] = data
        thumbnailCacheVersions[assetID, default: 0] &+= 1
        thumbnailCacheOrder.removeAll { $0 == assetID }
        thumbnailCacheOrder.append(assetID)
        while thumbnailCacheOrder.count > thumbnailCacheCapacity {
            let evicted = thumbnailCacheOrder.removeFirst()
            thumbnailDataCache.removeValue(forKey: evicted)
            thumbnailCacheVersions.removeValue(forKey: evicted)
        }
    }

    func loadThumbnailResult(assetID: UUID) async -> AssetThumbnailLoadResult {
        if let cached = cachedThumbnailData(for: assetID) {
            return .loaded(cached)
        }
        if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
           downloadedAssetID == assetID
        {
            rememberThumbnailData(data, for: assetID)
            return .loaded(data)
        }
        let service = service
        let loadEpoch = thumbnailLoadEpoch
        do {
            let data = try await thumbnailLoadGate.withPermit {
                try Task.checkCancellation()
                return try await service.loadThumbnail(assetID: assetID)
            }
            guard loadEpoch == thumbnailLoadEpoch else {
                return .cancelled
            }
            rememberThumbnailData(data, for: assetID)
            return .loaded(data)
        } catch is CancellationError {
            return .cancelled
        } catch PhotosLibraryError.cloudOnly {
            return .cloudOnly
        } catch PhotosLibraryError.authorizationDenied,
                PhotosLibraryError.authorizationRestricted
        {
            return .unavailable
        } catch DerivedImageError.derivedAssetNotFound,
                DerivedImageError.derivedAssetIneligible,
                DerivedImageError.derivedAuthorizationRequired
        {
            return .unavailable
        } catch {
            return .failed
        }
    }

    /// Retries transient thumbnail failures while the requesting SwiftUI task remains active.
    /// Cancellation settles as `.cancelled` without being promoted to a permanent blank state.
    func loadThumbnailResultWithRetry(
        assetID: UUID,
        maxAttempts: Int = 8
    ) async -> AssetThumbnailLoadResult {
        if let cached = cachedThumbnailData(for: assetID) {
            return .loaded(cached)
        }
        precondition(maxAttempts > 0)
        var attempt = 0
        while true {
            if Task.isCancelled {
                return .cancelled
            }
            let result = await loadThumbnailResult(assetID: assetID)
            switch result {
            case .loaded, .cloudOnly, .unavailable, .cancelled:
                return result
            case .failed:
                attempt += 1
                if attempt >= maxAttempts {
                    // Stay retryable for the visible-cell loop; only definitive
                    // eligibility/auth failures settle as `.unavailable`.
                    return .failed
                }
                let delayNanoseconds = UInt64(
                    min(50_000_000.0 * pow(2.0, Double(attempt - 1)), 1_200_000_000.0)
                )
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .cancelled
                }
            }
        }
    }

    func warmGridThumbnail(for assetID: UUID) async {
        guard cachedThumbnailData(for: assetID) == nil else { return }
        if case let .loaded(data) = await loadThumbnailResultWithRetry(assetID: assetID) {
            rememberThumbnailData(data, for: assetID)
        }
    }

    func previewData(assetID: UUID) async -> Data? {
        do {
            let data = try await service.loadPreview(assetID: assetID)
            if primarySelectedAssetID == assetID,
               cloudPreviewState.assetID == assetID
            {
                cloudPreviewState = .hidden
            }
            Task { [weak self] in
                await self?.warmGridThumbnail(for: assetID)
            }
            return data
        } catch PhotosLibraryError.cloudOnly {
            if primarySelectedAssetID == assetID {
                cloudPreviewState = .available(assetID: assetID)
            }
            return nil
        } catch {
            return nil
        }
    }

    func downloadCloudPreview(assetID: UUID) {
        guard primarySelectedAssetID == assetID else { return }
        cancelCloudPreviewTask(resetToAvailable: false)
        let requestID = UUID()
        cloudPreviewRequestID = requestID
        cloudPreviewState = .downloading(assetID: assetID, progress: 0)
        let service = service
        let model = self
        cloudPreviewTask = Task {
            do {
                let data = try await service.downloadCloudPreview(assetID: assetID) { progress in
                    Task { @MainActor in
                        guard model.cloudPreviewRequestID == requestID,
                              model.primarySelectedAssetID == assetID
                        else {
                            return
                        }
                        model.cloudPreviewState = .downloading(
                            assetID: assetID,
                            progress: min(max(progress, 0), 1)
                        )
                    }
                }
                try Task.checkCancellation()
                guard model.cloudPreviewRequestID == requestID,
                      model.primarySelectedAssetID == assetID
                else {
                    return
                }
                model.cloudPreviewState = .downloaded(assetID: assetID, data: data)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            } catch is CancellationError {
                guard model.cloudPreviewRequestID == requestID else { return }
                model.cloudPreviewState = .available(assetID: assetID)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            } catch {
                guard model.cloudPreviewRequestID == requestID else { return }
                model.cloudPreviewState = .failed(assetID: assetID)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            }
        }
    }

    func cancelCloudPreviewDownload(assetID: UUID) {
        guard cloudPreviewState.assetID == assetID else { return }
        cancelCloudPreviewTask(resetToAvailable: true)
    }

    func retryCloudPreviewDownload(assetID: UUID) {
        guard cloudPreviewState == .failed(assetID: assetID) else { return }
        downloadCloudPreview(assetID: assetID)
    }

    func selectAsset(
        _ assetID: UUID,
        additive: Bool = false,
        extendRange: Bool = false
    ) async {
        let orderedAssetIDs = displayedAssetIDsInGridOrder
        if extendRange,
           let anchorID = selectionAnchorID,
           let anchorIndex = orderedAssetIDs.firstIndex(of: anchorID),
           let targetIndex = orderedAssetIDs.firstIndex(of: assetID)
        {
            let range = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
            let rangeIDs = Set(range.map { orderedAssetIDs[$0] })
            selectedAssetIDs = additive ? selectedAssetIDs.union(rangeIDs) : rangeIDs
        } else if additive {
            if selectedAssetIDs.contains(assetID) {
                selectedAssetIDs.remove(assetID)
            } else {
                selectedAssetIDs.insert(assetID)
            }
            selectionAnchorID = assetID
        } else {
            selectedAssetIDs = [assetID]
            selectionAnchorID = assetID
        }
        if reviewMode != nil {
            if selectedAssetIDs.count == 1, let selectedAssetID = selectedAssetIDs.first {
                selectedReviewItemID = reviewQueueItems.first(where: {
                    $0.assetID == selectedAssetID
                })?.id
            } else {
                selectedReviewItemID = nil
            }
        }
        if selectedAssetIDs.count != 1 {
            isSinglePhotoPresented = false
        }
        resetCloudPreviewIfSelectionChanged()
        resetLocalModelSuggestionsForSelection()
        let selectionRefreshed = await refreshInspector()
        if selectionRefreshed, notice == .tagSelectionRefreshFailed {
            notice = nil
        }
    }

    func selectAssets(
        _ assetIDs: Set<UUID>,
        additive: Bool = false,
        shouldRefreshInspector: Bool = true
    ) async {
        let visibleIDs = Set(displayedAssetIDsInGridOrder)
        let normalizedIDs = assetIDs.intersection(visibleIDs)

        if additive {
            selectedAssetIDs.formUnion(normalizedIDs)
        } else {
            selectedAssetIDs = normalizedIDs
        }

        if let firstSelected = displayedAssetIDsInGridOrder.first(where: { selectedAssetIDs.contains($0) }) {
            selectionAnchorID = firstSelected
        } else {
            selectionAnchorID = nil
        }
        if reviewMode != nil {
            if selectedAssetIDs.count == 1, let selectedAssetID = selectedAssetIDs.first {
                selectedReviewItemID = reviewQueueItems.first(where: {
                    $0.assetID == selectedAssetID
                })?.id
            } else {
                selectedReviewItemID = nil
            }
        }

        if selectedAssetIDs.count != 1 {
            isSinglePhotoPresented = false
        }
        resetCloudPreviewIfSelectionChanged()
        resetLocalModelSuggestionsForSelection()

        guard shouldRefreshInspector else { return }

        let selectionRefreshed = await refreshInspector()
        if selectionRefreshed, notice == .tagSelectionRefreshFailed {
            notice = nil
        }
    }

    func selectReviewItem(_ itemID: ReviewQueueItemID) async {
        guard let item = reviewQueueItems.first(where: { $0.id == itemID }) else { return }
        await selectAsset(item.assetID)
        selectedReviewItemID = itemID
    }

    func selectAllVisibleAssets(additive: Bool = false) async {
        await selectAssets(Set(displayedAssetIDsInGridOrder), additive: additive)
    }

    private var displayedAssetIDsInGridOrder: [UUID] {
        if reviewMode != nil {
            reviewQueueItems.map(\.assetID)
        } else {
            items.map(\.assetID)
        }
    }

    func requestLocalModelSuggestions() async {
        guard let runtime = localModelSuggestions,
              let assetID = primarySelectedAssetID
        else {
            return
        }
        let requestID = UUID()
        localModelSuggestionTrack = .standard
        localModelSuggestionRequestID = requestID
        localModelSuggestionState = .loading(assetID: assetID)

        do {
            let availability = try await runtime.client.standardCapability()
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            guard case let .available(capability) = availability else {
                throw LocalModelSuggestionClientError.serviceUnavailable
            }
            let package = try Self.approvedStandardPackage(for: capability)
            let expectedTarget = capability.target
            let service = service
            _ = try await Self.offMain {
                try service.installStandardOntologyPackage(package)
            }
            tags = try await Self.offMain { try service.listTags() }
            tagGroups = try await Self.offMain { try service.listTagGroups() }
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            let requestedDetail = try await Self.offMain {
                try service.fetchInspectorDetail(assetID: assetID)
            }
            guard requestedDetail.assetID == assetID,
                  requestedDetail.contentRevision > 0
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            let imageData: Data
            if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
               downloadedAssetID == assetID
            {
                imageData = data
            } else {
                imageData = try await service.loadPreview(assetID: assetID)
            }
            let suggestions = try await runtime.client.suggestions(
                imageData: imageData,
                requestID: requestID.uuidString.lowercased(),
                target: .standard(expectedTarget)
            )
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            let currentDetail = try await Self.offMain {
                try service.fetchInspectorDetail(assetID: assetID)
            }
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            guard currentDetail.assetID == assetID,
                  currentDetail.contentRevision == requestedDetail.contentRevision
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            let reviewPort = review
            try await Self.offMain {
                _ = try reviewPort.replaceStandardSuggestions(
                    assetID: assetID,
                    contentRevision: requestedDetail.contentRevision,
                    suggestions: suggestions,
                    expectedTarget: expectedTarget
                )
            }
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .results(assetID: assetID, suggestions: suggestions)
            localModelSuggestionRequestID = nil
            await refreshReviewState()
        } catch PhotosLibraryError.cloudOnly {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .previewUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .serviceUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .failed(assetID: assetID)
            localModelSuggestionRequestID = nil
        }
    }

    func requestPersonalModelSuggestions() async {
        guard let runtime = localModelSuggestions,
              let assetID = primarySelectedAssetID
        else {
            return
        }
        let requestID = UUID()
        localModelSuggestionTrack = .personal
        localModelSuggestionRequestID = requestID
        localModelSuggestionState = .loading(assetID: assetID)

        do {
            let availability = try await runtime.client.personalCapability()
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            guard case let .available(capability) = availability else {
                localModelSuggestionState = .personalUnavailable(assetID: assetID)
                localModelSuggestionRequestID = nil
                return
            }
            let activeTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            try Self.validatePersonalCapability(
                capability,
                catalogScopeID: runtime.catalogScopeID,
                mediaKind: selectedMediaKind,
                activeTagIDs: activeTagIDs
            )

            let imageData: Data
            if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
               downloadedAssetID == assetID
            {
                imageData = data
            } else {
                imageData = try await service.loadPreview(assetID: assetID)
            }
            let suggestions = try await runtime.client.suggestions(
                imageData: imageData,
                requestID: requestID.uuidString.lowercased(),
                target: .personal(capability.target)
            )
            let currentActiveTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            _ = try Self.personalPredictions(
                suggestions,
                capability: capability,
                activeTagIDs: currentActiveTagIDs
            )
            localModelSuggestionState = .results(assetID: assetID, suggestions: suggestions)
            localModelSuggestionRequestID = nil
        } catch PhotosLibraryError.cloudOnly {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .previewUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .serviceUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .failed(assetID: assetID)
            localModelSuggestionRequestID = nil
        }
    }

    func generateStandardLibrarySuggestions() async {
        guard !isGeneratingStandardLibrarySuggestions else { return }
        guard let runtime = localModelSuggestions else {
            standardLibrarySuggestionState = .serviceUnavailable
            return
        }

        standardLibrarySuggestionState = .waiting(checked: 0, suggested: 0, skipped: 0)
        do {
            let availability = try await runtime.client.standardCapability()
            guard case let .available(capability) = availability else {
                throw LocalModelSuggestionClientError.serviceUnavailable
            }
            let package = try Self.approvedStandardPackage(for: capability)
            let service = service
            _ = try await Self.offMain {
                try service.installStandardOntologyPackage(package)
            }
            tags = try await Self.offMain { try service.listTags() }
            tagGroups = try await Self.offMain { try service.listTagGroups() }
            let reviewPort = review
            let sourceIDs = resolvedReviewSourceFilter
            let mediaKind = selectedMediaKind
            try await Self.offMain {
                _ = try reviewPort.enqueueStandardLibrarySuggestions(
                    mediaKind: mediaKind,
                    target: capability.target,
                    sourceIDs: sourceIDs
                )
            }
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch PersonalizationReviewError.activeJobConflict {
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            standardLibrarySuggestionState = .serviceUnavailable
        } catch is CancellationError {
            standardLibrarySuggestionState = .idle
        } catch {
            standardLibrarySuggestionState = .failed
        }
    }

    func generatePersonalLibrarySuggestions() async {
        if localModelSuggestions == nil, supportsAppPersonalSampleSuggestions {
            await generateAppPersonalSampleSuggestions()
            return
        }
        guard !isGeneratingPersonalLibrarySuggestions,
              !isRebuildingPersonalModel
        else { return }
        guard let runtime = localModelSuggestions else {
            personalLibrarySuggestionState = .serviceUnavailable
            return
        }

        personalLibrarySuggestionState = .waiting(checked: 0, suggested: 0, skipped: 0)

        do {
            let availability = try await runtime.client.personalCapability()
            guard case let .available(capability) = availability else {
                let reviewPort = review
                let mediaKind = selectedMediaKind
                try await Self.offMain {
                    try reviewPort.invalidatePersonalSuggestionBundles(mediaKind: mediaKind)
                }
                await refreshReviewState()
                personalLibrarySuggestionState = .personalUnavailable
                return
            }
            try Self.validatePersonalCapability(
                capability,
                catalogScopeID: runtime.catalogScopeID,
                mediaKind: selectedMediaKind,
                activeTagIDs: Set(tags.filter { $0.state == .active }.map(\.id))
            )

            let reviewPort = review
            let sourceIDs = resolvedReviewSourceFilter
            try await Self.offMain {
                _ = try reviewPort.enqueuePersonalLibrarySuggestions(
                    capability: capability,
                    sourceIDs: sourceIDs
                )
            }
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch PersonalizationReviewError.activeJobConflict {
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch LocalModelSuggestionClientError.identityMismatch {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .failed
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 409 && code == "personal_bundle_mismatch"
        {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .failed
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 503 && code == "personal_bundle_unavailable"
        {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .personalUnavailable
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            personalLibrarySuggestionState = .serviceUnavailable
        } catch let LocalModelSuggestionClientError.rejected(statusCode, _)
            where statusCode == 503
        {
            personalLibrarySuggestionState = .serviceUnavailable
        } catch is CancellationError {
            personalLibrarySuggestionState = .idle
        } catch {
            personalLibrarySuggestionState = .failed
        }
    }

    func generateAppPersonalSampleSuggestions() async {
        guard canGenerateAppPersonalSampleSuggestions,
              let suggester = appPersonalSampleSuggester,
              let cache = selectedAssetEmbeddingCache
        else {
            return
        }

        isGeneratingAppPersonalSampleSuggestions = true
        appPersonalSampleSuggestionProgress = nil
        notice = nil
        personalLibrarySuggestionState = .waiting(checked: 0, suggested: 0, skipped: 0)
        defer {
            isGeneratingAppPersonalSampleSuggestions = false
            appPersonalSampleSuggestionProgress = nil
        }

        do {
            let candidates = try await resolveAppPersonalSampleCandidates()
            guard !candidates.isEmpty else {
                notice = .personalSampleSuggestionsNotReady
                personalLibrarySuggestionState = .personalUnavailable
                return
            }

            let total = candidates.count
            personalLibrarySuggestionState = .running(
                checked: 0,
                suggested: 0,
                skipped: 0
            )
            appPersonalSampleSuggestionProgress = (0, 0, 0, total)

            let service = service
            let batch = try await suggester.suggest(
                mediaKind: selectedMediaKind,
                candidates: candidates,
                maximumSuggestionsPerAsset:
                    AppPersonalSampleSuggestionLimits.defaultMaximumSuggestionsPerAsset,
                embedding: { candidate in
                    let result = try await cache.cacheSelectedAsset(
                        assetID: candidate.assetID,
                        contentRevision: candidate.contentRevision,
                        imageData: {
                            try await service.loadPreview(assetID: candidate.assetID)
                        }
                    )
                    return AppCoreMLEmbedding(identity: result.identity, values: result.values)
                }
            )

            let reviewPort = review
            let inserted = try await Self.offMain {
                // Activate and persist per tag: each personal model is single-tag.
                for capability in batch.capabilities {
                    try reviewPort.activatePersonalSuggestionBundle(capability)
                }
                var inserted = 0
                for result in batch.results {
                    let predictionsByTag = Dictionary(
                        grouping: result.predictions,
                        by: \.tagID
                    )
                    for capability in batch.capabilities {
                        guard let tagID = capability.tagIDs.first,
                              let predictions = predictionsByTag[tagID],
                              !predictions.isEmpty
                        else {
                            continue
                        }
                        inserted += try reviewPort.replacePersonalSuggestions(
                            candidate: result.candidate,
                            predictions: predictions,
                            expectedCapability: capability
                        )
                    }
                }
                return inserted
            }

            let checked = candidates.count
            let skipped = batch.skippedCount
            await refreshReviewState()
            // App 路径不入 job 队列；refresh 会把状态清回 idle，完成后需再写回。
            personalLibrarySuggestionState = .completed(
                checked: checked,
                suggested: inserted,
                skipped: skipped
            )
            notice = .personalSampleSuggestionsCompleted(
                checked: checked,
                suggested: inserted,
                skipped: skipped
            )
        } catch AppPersonalSampleSuggestionError.personalUnavailable {
            notice = .personalSampleSuggestionsNotReady
            personalLibrarySuggestionState = .personalUnavailable
        } catch AppPersonalSampleSuggestionError.modelUnavailable {
            notice = .personalSampleSuggestionsModelUnavailable
            personalLibrarySuggestionState = .serviceUnavailable
        } catch is CancellationError {
            personalLibrarySuggestionState = .idle
        } catch {
            notice = .personalSampleSuggestionsFailed
            personalLibrarySuggestionState = .failed
        }
    }

    func generateAppPersonalTagLibrarySuggestions(
        tagID: UUID,
        displayName: String,
        sourceIDs: [UUID]? = nil,
        method: SuggestionGenerationMethod = .personalModel
    ) async {
        guard method == .personalModel || method == .personalAdamW else { return }
        guard let overview = suggestionOverviews.first(where: { $0.id == tagID }) else {
            notice = method == .personalAdamW
                ? .personalAdamWTagLibrarySuggestionsNotReady
                : .personalTagLibrarySuggestionsNotReady
            personalLibrarySuggestionState = .personalUnavailable
            return
        }
        guard let cache = selectedAssetEmbeddingCache else {
            notice = .personalTagLibrarySuggestionsModelUnavailable
            personalLibrarySuggestionState = .serviceUnavailable
            return
        }
        let suggester: any AppPersonalTagLibrarySuggesting
        let thresholdMethod: SuggestionScoreThresholdMethod
        switch method {
        case .personalModel:
            guard canGenerateAppPersonalTagLibrarySuggestions(for: overview),
                  let value = appPersonalTagLibrarySuggester
            else {
                notice = .personalTagLibrarySuggestionsNotReady
                personalLibrarySuggestionState = .personalUnavailable
                return
            }
            suggester = value
            thresholdMethod = .personalCentroid
        case .personalAdamW:
            guard canGenerateAppPersonalAdamWTagLibrarySuggestions(for: overview),
                  let value = appPersonalAdamWTagLibrarySuggester
            else {
                notice = appPersonalAdamWTagLibrarySuggester == nil
                    ? .personalAdamWTagLibrarySuggestionsNotReady
                    : .personalAdamWTagLibrarySuggestionsTagNotInModel
                personalLibrarySuggestionState = .personalUnavailable
                return
            }
            suggester = value
            thresholdMethod = .personalAdamW
        case .featureKnn:
            return
        }

        isGeneratingAppPersonalTagLibrarySuggestions = true
        appPersonalTagLibrarySuggestionProgress = nil
        notice = nil
        personalLibrarySuggestionState = .waiting(checked: 0, suggested: 0, skipped: 0)
        defer {
            isGeneratingAppPersonalTagLibrarySuggestions = false
            appPersonalTagLibrarySuggestionProgress = nil
        }

        do {
            let candidates = try await resolveAllPersonalSuggestionCandidates(
                tagID: tagID,
                sourceIDs: sourceIDs ?? resolvedReviewSourceFilter
            )
            guard !candidates.isEmpty else {
                notice = method == .personalAdamW
                    ? .personalAdamWTagLibrarySuggestionsNotReady
                    : .personalTagLibrarySuggestionsNotReady
                personalLibrarySuggestionState = .personalUnavailable
                return
            }

            let total = candidates.count
            personalLibrarySuggestionState = .running(
                checked: 0,
                suggested: 0,
                skipped: 0
            )
            appPersonalTagLibrarySuggestionProgress = (0, 0, 0, total)

            let service = service
            let minimumScore = effectiveSuggestionMinScore(
                tagID: tagID,
                method: thresholdMethod
            )
            let maximumPendingCount = maxPendingSuggestionsPerTag
            let batch = try await suggester.suggest(
                mediaKind: selectedMediaKind,
                tagID: tagID,
                candidates: candidates,
                maximumPendingCount: maximumPendingCount,
                minimumScore: minimumScore,
                embedding: { candidate in
                    let result = try await cache.cacheSelectedAsset(
                        assetID: candidate.assetID,
                        contentRevision: candidate.contentRevision,
                        imageData: {
                            try await service.loadPreview(assetID: candidate.assetID)
                        }
                    )
                    return AppCoreMLEmbedding(identity: result.identity, values: result.values)
                },
                progress: { [weak self] checked, suggested, skipped in
                    Task { @MainActor in
                        guard let self else { return }
                        self.appPersonalTagLibrarySuggestionProgress = (
                            checked,
                            suggested,
                            skipped,
                            total
                        )
                        self.personalLibrarySuggestionState = .running(
                            checked: checked,
                            suggested: suggested,
                            skipped: skipped
                        )
                    }
                }
            )

            let reviewPort = review
            let inserted = try await Self.offMain {
                try reviewPort.activatePersonalSuggestionBundle(batch.capability)
                return try reviewPort.replacePersonalTagLibrarySuggestions(
                    tagID: batch.tagID,
                    hits: batch.hits,
                    expectedCapability: batch.capability,
                    maximumPendingCount: maximumPendingCount
                )
            }

            await refreshReviewState()
            personalLibrarySuggestionState = .completed(
                checked: batch.checkedCount,
                suggested: inserted,
                skipped: batch.skippedCount
            )
            if method == .personalAdamW {
                notice = .personalAdamWTagLibrarySuggestionsCompleted(
                    tagName: displayName,
                    candidates: batch.checkedCount,
                    aboveThreshold: batch.aboveThresholdCount,
                    inserted: inserted,
                    skipped: batch.skippedCount
                )
            } else {
                notice = .personalTagLibrarySuggestionsCompleted(
                    tagName: displayName,
                    candidates: batch.checkedCount,
                    aboveThreshold: batch.aboveThresholdCount,
                    inserted: inserted,
                    skipped: batch.skippedCount
                )
            }
        } catch AppPersonalTagLibrarySuggestionError.personalUnavailable {
            notice = method == .personalAdamW
                ? .personalAdamWTagLibrarySuggestionsNotReady
                : .personalTagLibrarySuggestionsNotReady
            personalLibrarySuggestionState = .personalUnavailable
        } catch AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel {
            notice = method == .personalAdamW
                ? .personalAdamWTagLibrarySuggestionsTagNotInModel
                : .personalTagLibrarySuggestionsTagNotInModel
            personalLibrarySuggestionState = .personalUnavailable
        } catch AppPersonalTagLibrarySuggestionError.modelUnavailable {
            notice = .personalTagLibrarySuggestionsModelUnavailable
            personalLibrarySuggestionState = .serviceUnavailable
        } catch is CancellationError {
            notice = nil
            personalLibrarySuggestionState = .idle
        } catch {
            notice = method == .personalAdamW
                ? .personalAdamWTagLibrarySuggestionsFailed
                : .personalTagLibrarySuggestionsFailed
            personalLibrarySuggestionState = .failed
        }
    }


    private func resolveAllPersonalSuggestionCandidates(
        tagID: UUID,
        sourceIDs: [UUID]? = nil
    ) async throws -> [PersonalSuggestionCandidate] {
        let reviewPort = review
        let mediaKind = selectedMediaKind
        let pageSize = AppPersonalTagLibrarySuggestionLimits.candidatePageSize
        var candidates: [PersonalSuggestionCandidate] = []
        var afterAssetID: UUID?
        while true {
            let pageAfter = afterAssetID
            let page = try await Self.offMain {
                try reviewPort.personalSuggestionCandidates(
                    mediaKind: mediaKind,
                    afterAssetID: pageAfter,
                    limit: pageSize,
                    sourceIDs: sourceIDs,
                    excludingDecisionsForTagID: tagID
                )
            }
            if page.isEmpty { break }
            candidates.append(contentsOf: page)
            afterAssetID = page.last?.assetID
            if page.count < pageSize { break }
        }
        return candidates
    }

    private func resolveAppPersonalSampleCandidates() async throws -> [PersonalSuggestionCandidate] {
        let limit = maxPendingSuggestionsPerTag
        let selected = selectedAssetIDs
        if !selected.isEmpty {
            let orderedIDs = displayedAssetIDsInGridOrder.filter(selected.contains)
            let remaining = selected.subtracting(orderedIDs).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let assetIDs = Array((orderedIDs + remaining).prefix(limit))
            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.assetID, $0) })
            let service = service
            var candidates: [PersonalSuggestionCandidate] = []
            for assetID in assetIDs {
                let contentRevision: Int
                if let item = itemsByID[assetID], item.contentRevision > 0 {
                    contentRevision = item.contentRevision
                } else {
                    let detail = try await Self.offMain {
                        try service.fetchInspectorDetail(assetID: assetID)
                    }
                    guard detail.assetID == assetID, detail.contentRevision > 0 else {
                        continue
                    }
                    contentRevision = detail.contentRevision
                }
                candidates.append(
                    PersonalSuggestionCandidate(
                        assetID: assetID,
                        contentRevision: contentRevision
                    )
                )
            }
            return candidates
        }

        let reviewPort = review
        let mediaKind = selectedMediaKind
        return try await Self.offMain {
            try reviewPort.personalSuggestionCandidates(
                mediaKind: mediaKind,
                afterAssetID: nil,
                limit: limit,
                sourceIDs: nil,
                excludingDecisionsForTagID: nil
            )
        }
    }

    private func invalidatePersonalLibrarySuggestionBundle() async {
        let reviewPort = review
        let mediaKind = selectedMediaKind
        try? await Self.offMain {
            try reviewPort.invalidatePersonalSuggestionBundles(mediaKind: mediaKind)
        }
        await refreshReviewState()
    }

    private static func validatePersonalCapability(
        _ capability: PersonalModelSuggestionCapability,
        catalogScopeID: String,
        mediaKind: MediaKind,
        activeTagIDs: Set<UUID>
    ) throws {
        let target = capability.target
        guard target.catalogScopeID == catalogScopeID,
              target.mediaKind == mediaKind,
              !target.bundleID.isEmpty,
              !target.bundleRevision.isEmpty,
              !target.provider.isEmpty,
              !target.modelID.isEmpty,
              !target.modelRevision.isEmpty,
              !target.preprocessingRevision.isEmpty,
              target.elementCount > 0,
              isLowercaseSHA256(target.labelVocabularyRevision),
              isLowercaseSHA256(target.weightsSHA256),
              !target.policyRevision.isEmpty,
              // Personal models are published/scored per tag.
              capability.tagIDs.count == 1,
              Set(capability.tagIDs).isSubset(of: activeTagIDs)
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
    }

    private static func approvedStandardPackage(
        for capability: StandardModelSuggestionCapability
    ) throws -> StandardOntologyPackageInput {
        let package = StandardOntologyCatalog.bundledSceneFixture
        guard capability.target.standardPackID == package.standardPackID,
              capability.target.standardPackRevision == package.standardPackRevision,
              capability.manifestSHA256 == package.manifestSHA256,
              capability.ontologyID == package.ontologyID,
              capability.ontologyRevision == package.ontologyRevision,
              capability.provider == package.provider,
              capability.modelID == package.modelID,
              capability.modelRevision == package.modelRevision,
              capability.preprocessingRevision == package.preprocessingRevision,
              capability.mappingRevision == package.mappingRevision,
              capability.policyRevision == package.policyRevision,
              capability.weightsSHA256 == package.weightsSHA256
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return package
    }

    private static func personalPredictions(
        _ suggestions: [LocalModelSuggestion],
        capability: PersonalModelSuggestionCapability,
        activeTagIDs: Set<UUID>
    ) throws -> [PersonalSuggestionPrediction] {
        let tagIDs = suggestions.compactMap(\.tagID)
        guard tagIDs.count == suggestions.count,
              Set(tagIDs).count == tagIDs.count,
              suggestions.allSatisfy({ suggestion in
                  guard let tagID = suggestion.tagID else { return false }
                  return suggestion.score.isFinite
                      && suggestion.track == .personal
                      && suggestion.conceptID == nil
                      && suggestion.recommendedState == .suggested
                      && capability.tagIDs.contains(tagID)
                      && activeTagIDs.contains(tagID)
                      && suggestion.catalogScopeID == capability.target.catalogScopeID
                      && suggestion.bundleID == capability.target.bundleID
                      && suggestion.bundleRevision == capability.target.bundleRevision
                      && suggestion.provider == capability.target.provider
                      && suggestion.modelID == capability.target.modelID
                      && suggestion.modelRevision == capability.target.modelRevision
                      && suggestion.preprocessingRevision == capability.target.preprocessingRevision
                      && suggestion.elementCount == capability.target.elementCount
                      && suggestion.labelVocabularyRevision == capability.target.labelVocabularyRevision
                      && suggestion.weightsSHA256 == capability.target.weightsSHA256
                      && suggestion.policyRevision == capability.target.policyRevision
                      && suggestion.standardPackID == nil
                      && suggestion.standardPackRevision == nil
              })
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return suggestions.compactMap { suggestion in
            suggestion.tagID.map {
                PersonalSuggestionPrediction(tagID: $0, score: suggestion.score)
            }
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }

    func applyLocalModelSuggestionDecision(
        _ suggestion: LocalModelSuggestion,
        action: LibraryTagDecisionAction
    ) async {
        guard suggestion.track == .personal,
              let tagID = suggestion.tagID,
              tags.contains(where: { $0.id == tagID && $0.state == .active }),
              case let .results(assetID, suggestions) = localModelSuggestionState,
              primarySelectedAssetID == assetID,
              suggestions.contains(suggestion),
              action == .accept || action == .reject
        else {
            return
        }
        guard await applyTagDecision(tagID: tagID, action: action, assetIDs: [assetID]) else {
            return
        }
        localModelSuggestionState = .results(
            assetID: assetID,
            suggestions: suggestions.filter { $0 != suggestion }
        )
    }

    func rebuildPersonalModel() async {
        guard !isRebuildingPersonalModel,
              !isRebuildingPersonalAdamWModel,
              !isGeneratingPersonalLibrarySuggestions
        else { return }
        if let appPersonalModelRebuilder {
            await rebuildAppPersonalModel(
                using: appPersonalModelRebuilder,
                family: .centroid,
                trainingTagIDs: Set(
                    selectedTagFilterDecisions.compactMap {
                        $0.value == .accepted ? $0.key : nil
                    }
                ),
                selectedAssetIDs: selectedAssetIDs
            )
            return
        }
        guard let runtime = localModelSuggestions else {
            notice = .personalModelRebuildServiceUnavailable
            return
        }
        isRebuildingPersonalModel = true
        notice = nil
        defer { isRebuildingPersonalModel = false }

        do {
            let snapshot = try review.personalTrainingSnapshot()
            let activeTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            guard snapshot.catalogScopeID == runtime.catalogScopeID,
                  !snapshot.personalTagIDs.isEmpty,
                  Set(snapshot.personalTagIDs).count == snapshot.personalTagIDs.count,
                  Set(snapshot.personalTagIDs).isSubset(of: activeTagIDs),
                  Self.hasMinimumPersonalTrainingSamples(snapshot)
            else {
                notice = .personalModelRebuildNotReady
                return
            }

            let expectedActiveBundle: PersonalModelActiveBundleIdentity?
            switch try await runtime.client.personalCapability() {
            case .unavailable:
                expectedActiveBundle = nil
            case let .available(capability):
                guard capability.target.catalogScopeID == runtime.catalogScopeID else {
                    throw LocalModelSuggestionClientError.identityMismatch
                }
                expectedActiveBundle = PersonalModelActiveBundleIdentity(
                    bundleRevision: capability.target.bundleRevision,
                    weightsSHA256: capability.target.weightsSHA256
                )
            }

            let revisions = Set(snapshot.decisions.map {
                PersonalTrainingAssetRevision(
                    assetID: $0.assetID,
                    contentRevision: $0.contentRevision
                )
            }).sorted(by: PersonalTrainingAssetRevision.isOrderedBefore)
            var encoder: PersonalTrainingEncoderIdentity?
            var embeddings: [PersonalTrainingEmbeddingRow] = []
            for revision in revisions {
                try Task.checkCancellation()
                let imageData = try await service.loadPreview(assetID: revision.assetID)
                let embedding = try await runtime.client.embedding(
                    imageData: imageData,
                    requestID: UUID().uuidString.lowercased(),
                    cacheKey: PersonalTrainingEmbeddingCacheKey(
                        catalogScopeID: runtime.catalogScopeID,
                        assetID: revision.assetID,
                        contentRevision: revision.contentRevision
                    )
                )
                if let encoder {
                    guard encoder == embedding.encoder else {
                        throw LocalModelSuggestionClientError.identityMismatch
                    }
                } else {
                    encoder = embedding.encoder
                }
                embeddings.append(
                    PersonalTrainingEmbeddingRow(
                        assetID: revision.assetID,
                        contentRevision: revision.contentRevision,
                        values: embedding.values
                    )
                )
            }

            try Task.checkCancellation()
            guard try review.personalTrainingSnapshot() == snapshot,
                  let encoder
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            let tagIDs = snapshot.personalTagIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let rebuildSnapshot = PersonalModelRebuildSnapshot(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: Self.decisionSnapshotRevision(snapshot),
                encoder: encoder,
                personalTagIDs: tagIDs,
                labelVocabularyRevision: Self.labelVocabularyRevision(tagIDs),
                embeddings: embeddings,
                decisions: snapshot.decisions
            )
            let requestID = UUID().uuidString.lowercased()
            let rebuilt = try await runtime.client.rebuildPersonalModel(
                requestID: requestID,
                expectedActiveBundle: expectedActiveBundle,
                snapshot: rebuildSnapshot
            )
            guard case let .available(confirmed) = try await runtime.client.personalCapability(),
                  confirmed == rebuilt
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            notice = .personalModelRebuildCompleted(
                tagCount: tagIDs.count,
                sampleCount: embeddings.count
            )
        } catch PhotosLibraryError.cloudOnly {
            notice = .personalModelRebuildPreviewUnavailable
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            notice = .personalModelRebuildServiceUnavailable
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 503
                && (code == "model_unavailable" || code == "personal_rebuild_unavailable")
        {
            notice = .personalModelRebuildServiceUnavailable
        } catch is CancellationError {
            notice = nil
        } catch {
            notice = .personalModelRebuildFailed
        }
    }

    func rebuildPersonalModel(tagIDs: Set<UUID>, assetIDs: Set<UUID>) async {
        guard !isRebuildingPersonalModel,
              !isRebuildingPersonalAdamWModel,
              !isGeneratingPersonalLibrarySuggestions,
              let rebuilder = appPersonalModelRebuilder
        else {
            if appPersonalModelRebuilder == nil {
                notice = .personalModelRebuildServiceUnavailable
            }
            return
        }
        await rebuildAppPersonalModel(
            using: rebuilder,
            family: .centroid,
            trainingTagIDs: tagIDs,
            selectedAssetIDs: assetIDs
        )
    }

    func cacheSelectedAssetEmbedding() async {
        guard !isCachingSelectedAssetEmbedding,
              let cache = selectedAssetEmbeddingCache,
              !selectedAssetIDs.isEmpty
        else {
            return
        }
        isCachingSelectedAssetEmbedding = true
        notice = nil
        defer { isCachingSelectedAssetEmbedding = false }

        let selected = selectedAssetIDs
        let orderedIDs = displayedAssetIDsInGridOrder.filter(selected.contains)
        let remaining = selected.subtracting(orderedIDs).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let assetIDs = orderedIDs + remaining
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.assetID, $0) })
        let service = service

        var prepared = 0
        var skipped = 0
        var cloudOnly = 0
        var failed = 0

        for assetID in assetIDs {
            do {
                let contentRevision: Int
                if let item = itemsByID[assetID], item.contentRevision > 0 {
                    contentRevision = item.contentRevision
                } else {
                    let detail = try await Self.offMain {
                        try service.fetchInspectorDetail(assetID: assetID)
                    }
                    guard detail.assetID == assetID, detail.contentRevision > 0 else {
                        throw AppSelectedAssetEmbeddingCacheError.invalidAsset
                    }
                    contentRevision = detail.contentRevision
                }

                let downloadedData: Data?
                if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
                   downloadedAssetID == assetID
                {
                    downloadedData = data
                } else {
                    downloadedData = nil
                }

                let result = try await cache.cacheSelectedAsset(
                    assetID: assetID,
                    contentRevision: contentRevision,
                    imageData: {
                        if let downloadedData { return downloadedData }
                        return try await service.loadPreview(assetID: assetID)
                    }
                )
                if result.origin == .cacheHit {
                    skipped += 1
                } else {
                    prepared += 1
                }
            } catch AppSelectedAssetEmbeddingCacheError.modelUnavailable {
                notice = .selectedAssetEmbeddingModelUnavailable
                return
            } catch PhotosLibraryError.cloudOnly {
                cloudOnly += 1
            } catch {
                failed += 1
            }
        }

        if assetIDs.count == 1 {
            if prepared == 1 || skipped == 1 {
                notice = .selectedAssetEmbeddingCached
            } else if cloudOnly == 1 {
                notice = .selectedAssetEmbeddingPreviewUnavailable
            } else {
                notice = .selectedAssetEmbeddingFailed
            }
            return
        }

        notice = .selectedAssetEmbeddingBatchCompleted(
            prepared: prepared,
            skipped: skipped,
            cloudOnly: cloudOnly,
            failed: failed
        )
    }

    func rebuildPersonalAdamWModel() async {
        guard !isRebuildingPersonalModel,
              !isRebuildingPersonalAdamWModel,
              !isGeneratingPersonalLibrarySuggestions,
              let rebuilder = appPersonalAdamWModelRebuilder
        else {
            if appPersonalAdamWModelRebuilder == nil {
                notice = .personalModelRebuildServiceUnavailable
            }
            return
        }
        await rebuildAppPersonalModel(
            using: rebuilder,
            family: .adamW,
            trainingTagIDs: Set(
                selectedTagFilterDecisions.compactMap {
                    $0.value == .accepted ? $0.key : nil
                }
            ),
            selectedAssetIDs: selectedAssetIDs
        )
    }

    func rebuildPersonalAdamWModel(tagIDs: Set<UUID>, assetIDs: Set<UUID>) async {
        guard !isRebuildingPersonalModel,
              !isRebuildingPersonalAdamWModel,
              !isGeneratingPersonalLibrarySuggestions,
              let rebuilder = appPersonalAdamWModelRebuilder
        else {
            if appPersonalAdamWModelRebuilder == nil {
                notice = .personalModelRebuildServiceUnavailable
            }
            return
        }
        await rebuildAppPersonalModel(
            using: rebuilder,
            family: .adamW,
            trainingTagIDs: tagIDs,
            selectedAssetIDs: assetIDs
        )
    }

    private func rebuildAppPersonalModel(
        using rebuilder: any AppPersonalModelRebuilding,
        family: AppPersonalLinearHeadFamily,
        trainingTagIDs requestedTrainingTagIDs: Set<UUID>,
        selectedAssetIDs: Set<UUID>
    ) async {
        switch family {
        case .centroid:
            isRebuildingPersonalModel = true
        case .adamW:
            isRebuildingPersonalAdamWModel = true
        }
        notice = nil
        defer {
            isRebuildingPersonalModel = false
            isRebuildingPersonalAdamWModel = false
            trainingWorkspaceActivity = nil
        }

        do {
            let activeTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            let trainingTagIDs = requestedTrainingTagIDs.intersection(activeTagIDs)
            guard !trainingTagIDs.isEmpty else {
                notice = family == .adamW
                    ? .personalAdamWRebuildTagSelectionRequired
                    : .personalModelRebuildTagSelectionRequired
                return
            }
            let method = family.trainingRunMethod
            let orderedTagIDs = trainingTagIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let scope: TrainingWorkspaceActivityScope = selectedAssetIDs.isEmpty
                ? .allSources
                : .selectedAssets(count: selectedAssetIDs.count)
            let review = review
            let mediaKind = selectedMediaKind
            let refreshTask = startTrainingWorkspaceAutoRefresh()
            defer { refreshTask?.cancel() }
            // One selected tag => one independent training_run / 训练工程.
            // Tags queue sequentially through the rebuilder but never share a
            // multi-tag snapshot; failure/skip of one tag does not unwind others.
            var totalSampleCount = 0
            var trainedTagCount = 0
            var skippedNotReadyCount = 0
            var failedTagCount = 0
            var cancelled = false
            var lastFailureNotice: LibraryWorkspaceNotice?
            for tagID in orderedTagIDs {
                let currentTagName = tags.first(where: { $0.id == tagID })?.displayName
                    ?? tagID.uuidString
                trainingWorkspaceActivity = TrainingWorkspaceActivity(
                    method: method,
                    tagNames: [currentTagName],
                    scope: scope,
                    sampleCount: nil,
                    phase: .preparingSamples
                )
                let singleTagIDs: Set<UUID> = [tagID]
                let snapshotSource = AppPersonalTrainingSnapshotPortSource {
                    try review.personalTrainingSnapshot(
                        mediaKind: mediaKind,
                        limitingToTagIDs: singleTagIDs,
                        limitingToAssetIDs: selectedAssetIDs.isEmpty ? nil : selectedAssetIDs
                    )
                }
                let snapshot: PersonalTrainingSnapshot
                do {
                    snapshot = try await snapshotSource.currentSnapshot()
                } catch {
                    failedTagCount += 1
                    lastFailureNotice = family == .adamW
                        ? .personalAdamWRebuildFailed
                        : .personalModelRebuildFailed
                    continue
                }
                guard Self.hasMinimumPersonalTrainingSamples(snapshot) else {
                    skippedNotReadyCount += 1
                    continue
                }
                let sampleCount = Set(snapshot.decisions.map {
                    PersonalTrainingAssetRevision(
                        assetID: $0.assetID,
                        contentRevision: $0.contentRevision
                    )
                }).count
                trainingWorkspaceActivity = TrainingWorkspaceActivity(
                    method: method,
                    tagNames: [currentTagName],
                    scope: scope,
                    sampleCount: sampleCount,
                    phase: .preparingEmbeddings(completed: 0, total: sampleCount)
                )
                guard await ensurePersonalTrainingSampleEmbeddingsCached(snapshot) else {
                    // ensurePersonalTrainingSampleEmbeddingsCached already set notice.
                    failedTagCount += 1
                    lastFailureNotice = notice
                    notice = nil
                    continue
                }
                trainingWorkspaceActivity = TrainingWorkspaceActivity(
                    method: method,
                    tagNames: [currentTagName],
                    scope: scope,
                    sampleCount: sampleCount,
                    phase: .trainingAndPublishing
                )
                do {
                    _ = try await rebuilder.rebuild(snapshotSource: snapshotSource)
                    totalSampleCount += sampleCount
                    trainedTagCount += 1
                } catch let error as AppPersonalModelRebuildError {
                    switch error {
                    case .cancelled:
                        cancelled = true
                    case .invalidSnapshot:
                        skippedNotReadyCount += 1
                    case .modelUnavailable:
                        failedTagCount += 1
                        lastFailureNotice = .personalModelRebuildServiceUnavailable
                    case .embeddingUnavailable:
                        failedTagCount += 1
                        lastFailureNotice = .personalModelRebuildCacheUnavailable
                    case .alreadyRunning, .staleSnapshot:
                        failedTagCount += 1
                        lastFailureNotice = family == .adamW
                            ? .personalAdamWRebuildFailed
                            : .personalModelRebuildFailed
                    }
                    if cancelled { break }
                } catch is CancellationError {
                    cancelled = true
                    break
                } catch {
                    failedTagCount += 1
                    lastFailureNotice = family == .adamW
                        ? .personalAdamWRebuildFailed
                        : .personalModelRebuildFailed
                }
            }
            if cancelled {
                notice = nil
            } else if trainedTagCount > 0 {
                switch family {
                case .centroid:
                    notice = .personalModelRebuildCompleted(
                        tagCount: trainedTagCount,
                        sampleCount: totalSampleCount
                    )
                case .adamW:
                    notice = .personalAdamWRebuildCompleted(
                        tagCount: trainedTagCount,
                        sampleCount: totalSampleCount
                    )
                }
            } else if skippedNotReadyCount > 0, failedTagCount == 0 {
                notice = family == .adamW
                    ? .personalAdamWRebuildNotReady
                    : .personalModelRebuildNotReady
            } else {
                notice = lastFailureNotice ?? (family == .adamW
                    ? .personalAdamWRebuildFailed
                    : .personalModelRebuildFailed)
            }
        } catch {
            notice = family == .adamW
                ? .personalAdamWRebuildFailed
                : .personalModelRebuildFailed
        }
        await refreshTrainingWorkspace(presentation: .automatic)
    }

    private func startTrainingWorkspaceAutoRefresh() -> Task<Void, Never>? {
        guard trainingWorkspace != nil else { return nil }
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshTrainingWorkspace(presentation: .automatic)
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
            }
        }
    }

    /// Prepares embeddings for the resolved training snapshot samples.
    /// Returns false when preparation failed and `notice` was already set.
    private func ensurePersonalTrainingSampleEmbeddingsCached(
        _ snapshot: PersonalTrainingSnapshot
    ) async -> Bool {
        guard let cache = selectedAssetEmbeddingCache else {
            return true
        }
        let revisions = Set(snapshot.decisions.map {
            PersonalTrainingAssetRevision(
                assetID: $0.assetID,
                contentRevision: $0.contentRevision
            )
        }).sorted(by: PersonalTrainingAssetRevision.isOrderedBefore)
        guard !revisions.isEmpty else {
            return true
        }

        let service = service
        var cloudOnly = 0
        var failed = 0
        for (index, revision) in revisions.enumerated() {
            do {
                _ = try await cache.cacheSelectedAsset(
                    assetID: revision.assetID,
                    contentRevision: revision.contentRevision,
                    imageData: {
                        try await service.loadPreview(assetID: revision.assetID)
                    }
                )
            } catch AppSelectedAssetEmbeddingCacheError.modelUnavailable {
                notice = .selectedAssetEmbeddingModelUnavailable
                return false
            } catch PhotosLibraryError.cloudOnly {
                cloudOnly += 1
            } catch {
                failed += 1
            }
            if let activity = trainingWorkspaceActivity {
                trainingWorkspaceActivity = TrainingWorkspaceActivity(
                    method: activity.method,
                    tagNames: activity.tagNames,
                    scope: activity.scope,
                    sampleCount: activity.sampleCount,
                    phase: .preparingEmbeddings(
                        completed: index + 1,
                        total: revisions.count
                    )
                )
            }
        }

        if cloudOnly > 0 {
            notice = .personalModelRebuildPreviewUnavailable
            return false
        }
        if failed > 0 {
            notice = .personalModelRebuildCacheUnavailable
            return false
        }
        return true
    }

    private struct PersonalTrainingAssetRevision: Hashable {
        let assetID: UUID
        let contentRevision: Int

        static func isOrderedBefore(
            _ lhs: PersonalTrainingAssetRevision,
            _ rhs: PersonalTrainingAssetRevision
        ) -> Bool {
            let lhsID = lhs.assetID.uuidString.lowercased()
            let rhsID = rhs.assetID.uuidString.lowercased()
            return lhsID == rhsID
                ? lhs.contentRevision < rhs.contentRevision
                : lhsID < rhsID
        }
    }

    private static func hasMinimumPersonalTrainingSamples(
        _ snapshot: PersonalTrainingSnapshot
    ) -> Bool {
        guard !snapshot.personalTagIDs.isEmpty else {
            return false
        }
        return snapshot.personalTagIDs.allSatisfy { tagID in
            snapshot.decisions.filter {
                $0.tagID == tagID && $0.state == .manualAccepted
            }.count >= 2
        }
    }

    private static func labelVocabularyRevision(_ tagIDs: [UUID]) -> String {
        sha256(tagIDs.map { $0.uuidString.lowercased() }.joined(separator: "\n"))
    }

    private static func decisionSnapshotRevision(_ snapshot: PersonalTrainingSnapshot) -> String {
        let decisions = snapshot.decisions.sorted { lhs, rhs in
            let lhsKey = "\(lhs.tagID.uuidString.lowercased())|\(lhs.assetID.uuidString.lowercased())|\(lhs.contentRevision)|\(lhs.state.rawValue)"
            let rhsKey = "\(rhs.tagID.uuidString.lowercased())|\(rhs.assetID.uuidString.lowercased())|\(rhs.contentRevision)|\(rhs.state.rawValue)"
            return lhsKey < rhsKey
        }
        let lines = ["catalog|\(snapshot.catalogScopeID)"]
            + snapshot.personalTagIDs.map { "tag|\($0.uuidString.lowercased())" }.sorted()
            + decisions.map {
                "decision|\($0.assetID.uuidString.lowercased())|\($0.contentRevision)|\($0.tagID.uuidString.lowercased())|\($0.state.rawValue)"
            }
        return sha256(lines.joined(separator: "\n"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func toggleSinglePhotoView() {
        guard primarySelectedAssetID != nil else { return }
        isSinglePhotoPresented.toggle()
    }

    func openSinglePhotoView(assetID: UUID) async {
        guard items.contains(where: { $0.assetID == assetID })
            || reviewQueueItems.contains(where: { $0.assetID == assetID })
        else { return }
        await selectAsset(assetID)
        isSinglePhotoPresented = true
    }

    func openSinglePhotoView(reviewItemID: ReviewQueueItemID) async {
        guard reviewQueueItems.contains(where: { $0.id == reviewItemID }) else { return }
        await selectReviewItem(reviewItemID)
        isSinglePhotoPresented = true
    }

    func closeSinglePhotoView() {
        isSinglePhotoPresented = false
    }

    func moveSinglePhotoSelection(by offset: Int) async {
        guard isSinglePhotoPresented, offset != 0 else { return }
        if reviewMode != nil {
            await moveReviewPrimarySelection(
                in: offset > 0 ? .right : .left,
                columnCount: abs(offset)
            )
        } else {
            await movePrimarySelection(by: offset)
        }
    }

    func movePrimarySelection(by offset: Int) async {
        guard offset != 0, let currentID = primarySelectedAssetID else { return }

        if offset > 0,
           let currentIndex = items.firstIndex(where: { $0.assetID == currentID }),
           currentIndex + offset >= items.count,
           let lastLoadedID = items.last?.assetID
        {
            await loadMoreIfNeeded(currentAssetID: lastLoadedID)
        }

        guard let currentIndex = items.firstIndex(where: { $0.assetID == currentID }) else {
            return
        }
        let targetIndex = min(max(currentIndex + offset, 0), items.count - 1)
        guard targetIndex != currentIndex else { return }
        await selectAsset(items[targetIndex].assetID)
    }

    func movePrimarySelection(
        in direction: LibraryGridNavigationDirection,
        columnCount: Int
    ) async {
        if primarySelectedAssetID == nil {
            guard let firstAssetID = items.first?.assetID else { return }
            await selectAsset(firstAssetID)
            return
        }
        let columns = max(columnCount, 1)
        let offset = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        await movePrimarySelection(by: offset)
    }

    func movePrimarySelection(
        byPage direction: LibraryGridPageDirection,
        pageItemCount: Int
    ) async {
        if primarySelectedAssetID == nil {
            guard let firstAssetID = items.first?.assetID else { return }
            await selectAsset(firstAssetID)
            return
        }
        let distance = max(pageItemCount, 1)
        await movePrimarySelection(by: direction == .down ? distance : -distance)
    }

    func openSelectedOriginal() async {
        guard selectedAssetIDs.count == 1,
              let assetID = primarySelectedAssetID,
              !isOpeningOriginal
        else { return }
        isOpeningOriginal = true
        defer { isOpeningOriginal = false }
        do {
            notice = nil
            try await originalAssetOpener.openOriginalAsset(assetID: assetID)
        } catch {
            notice = .originalOpenFailed
        }
    }

    func applyTagDecision(tagID: UUID, action: LibraryTagDecisionAction) async {
        let assetIDs = Array(selectedAssetIDs)
        _ = await applyTagDecision(tagID: tagID, action: action, assetIDs: assetIDs)
    }

    @discardableResult
    private func applyTagDecision(
        tagID: UUID,
        action: LibraryTagDecisionAction,
        assetIDs: [UUID]
    ) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        let service = service
        do {
            notice = nil
            let snapshot = try await Self.offMain {
                try service.mutateTag(tagID: tagID, assetIDs: assetIDs, action: action)
            }
            lastTagMutation = LibraryTagUndoRecord(snapshot: snapshot, appliedDecision: action.decision)
            applyGridDecision(snapshot: snapshot, newDecision: action.decision)
            await enqueueAutomaticPersonalModelRebuildIfReady()
            if mutationAffectsCurrentFilter(tagID: tagID) {
                await loadFirstPage()
            }
            await refreshInspector()
            await refreshReviewState()
            publishTagMutationNotice(
                count: assetIDs.count,
                tagDisplayName: tagDisplayName(for: tagID),
                action: Self.tagMutationFeedbackKind(for: action)
            )
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    func requestTagDecision(tagID: UUID, action: LibraryTagDecisionAction) async {
        await applyTagDecision(tagID: tagID, action: action)
    }

    func undoLastTagMutation() async {
        guard let undo = lastTagMutation else { return }
        let service = service
        do {
            notice = nil
            try await Self.offMain { try service.restoreTagMutation(undo.snapshot) }
            restoreGridDecision(undo)
            lastTagMutation = nil
            await enqueueAutomaticPersonalModelRebuildIfReady()
            if mutationAffectsCurrentFilter(tagID: undo.snapshot.tagID) {
                await loadFirstPage()
            }
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
            return
        }
    }

    func createAndAcceptTag(named rawName: String) async {
        let assetIDs = Array(selectedAssetIDs)
        await createAndAcceptTag(named: rawName, assetIDs: assetIDs)
    }

    private func createAndAcceptTag(named rawName: String, assetIDs: [UUID]) async {
        guard !assetIDs.isEmpty else { return }
        let service = service
        do {
            notice = nil
            let result = try await Self.offMain {
                try service.createTagAndAccept(rawName: rawName, assetIDs: assetIDs)
            }
            let snapshot = result.restoreSnapshot()
            lastTagMutation = LibraryTagUndoRecord(snapshot: snapshot, appliedDecision: .accepted)
            applyGridDecision(snapshot: snapshot, newDecision: .accepted)
            tags.append(TagListItem(
                id: result.tagID,
                displayName: result.displayName,
                state: .active,
                groupID: TagGroupSeed.classify(displayName: result.displayName).id
            ))
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            await enqueueAutomaticPersonalModelRebuildIfReady()
            if tagPresence != .any || !TagNameNormalizer.trimUnicodeWhiteSpace(searchText).isEmpty {
                await loadFirstPage()
            }
            let selectionRefreshed = await refreshInspector()
            if !selectionRefreshed {
                restoreCommittedNewTagPresentation(result, assetIDs: assetIDs)
                notice = .tagSelectionRefreshFailed
            } else {
                publishTagMutationNotice(
                    count: assetIDs.count,
                    tagDisplayName: result.displayName,
                    action: .createdAndApplied
                )
            }
        } catch {
            notice = tagNotice(for: error)
        }
    }

    func requestCreateAndAcceptTag(named rawName: String) async {
        guard case let .success(name) = TagNameNormalizer.validateAndNormalize(rawName) else {
            return
        }
        await createAndAcceptTag(named: name.displayName)
    }

    func installPresetTags() async {
        let service = service
        do {
            notice = nil
            let result = try await Self.offMain { try service.installPresetTags() }
            guard !result.createdTags.isEmpty else {
                notice = .presetTagsAlreadyAvailable
                return
            }
            tags.append(contentsOf: result.createdTags)
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            lastTagMutation = nil
            notice = .presetTagsInstalled(createdCount: result.createdTags.count)
            await refreshInspector()
        } catch {
            notice = tagNotice(for: error)
        }
    }

    func renameTag(_ tagID: UUID, to rawName: String) async -> Bool {
        let service = service
        do {
            notice = nil
            let renamed = try await Self.offMain {
                try service.renameTag(tagID: tagID, rawName: rawName)
            }
            guard let index = tags.firstIndex(where: { $0.id == tagID }) else {
                notice = .tagMutationFailed
                return false
            }
            tags[index] = renamed
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            lastTagMutation = nil
            await loadFirstPage()
            await refreshInspector()
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    func archiveTag(_ tagID: UUID) async -> Bool {
        let service = service
        do {
            notice = nil
            try await Self.offMain { try service.archiveTag(tagID: tagID) }
            tags.removeAll { $0.id == tagID }
            selectedTagFilterDecisions.removeValue(forKey: tagID)
            selectedTagFilterIDs.remove(tagID)
            excludedTagFilterIDs.remove(tagID)
            lastTagMutation = nil
            await enqueueAutomaticPersonalModelRebuildIfReady()
            await loadFirstPage()
            await refreshInspector()
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    func moveTag(_ tagID: UUID, toGroupID: UUID) async -> Bool {
        guard let previous = prepareMoveTag(tagID, toGroupID: toGroupID) else {
            return false
        }
        return await persistMoveTag(tagID, toGroupID: toGroupID, previous: previous)
    }

    /// Synchronously applies a move in memory so drop targets can return success immediately.
    @discardableResult
    func acceptAndEnqueueMoveTag(_ tagID: UUID, toGroupID: UUID) -> Bool {
        guard let previous = prepareMoveTag(tagID, toGroupID: toGroupID) else {
            return false
        }
        Task { _ = await self.persistMoveTag(tagID, toGroupID: toGroupID, previous: previous) }
        return true
    }

    private func prepareMoveTag(_ tagID: UUID, toGroupID: UUID) -> TagListItem? {
        guard tagGroups.contains(where: { $0.id == toGroupID }),
              let index = tags.firstIndex(where: { $0.id == tagID })
        else {
            return nil
        }
        let current = tags[index]
        guard current.groupID != toGroupID else {
            return nil
        }
        notice = nil
        tagOrderPreferences.remove(tagID, from: current.groupID)
        tags[index] = TagListItem(
            id: current.id,
            displayName: current.displayName,
            state: current.state,
            groupID: toGroupID
        )
        let destinationTags = tags.filter { $0.groupID == toGroupID }
        tagOrderPreferences.append(tagID, to: toGroupID, tags: destinationTags)
        tagOrderRevision &+= 1
        return current
    }

    private func persistMoveTag(
        _ tagID: UUID,
        toGroupID: UUID,
        previous: TagListItem
    ) async -> Bool {
        let service = service
        do {
            let moved = try await Self.offMain {
                try service.moveTag(tagID: tagID, toGroupID: toGroupID)
            }
            if let index = tags.firstIndex(where: { $0.id == tagID }) {
                tags[index] = moved
            } else {
                tags.append(moved)
            }
            return true
        } catch {
            if let index = tags.firstIndex(where: { $0.id == tagID }) {
                tags[index] = previous
            }
            notice = tagGroupNotice(for: error)
            return false
        }
    }

    func createTagGroup(named rawName: String) async -> Bool {
        let service = service
        do {
            notice = nil
            let created = try await Self.offMain {
                try service.createTagGroup(rawName: rawName)
            }
            tagGroups.append(created)
            tagGroups.sort {
                if $0.sortOrder != $1.sortOrder {
                    return $0.sortOrder < $1.sortOrder
                }
                return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
            return true
        } catch {
            notice = tagGroupNotice(for: error)
            return false
        }
    }

    func renameTagGroup(_ groupID: UUID, to rawName: String) async -> Bool {
        let service = service
        do {
            notice = nil
            let renamed = try await Self.offMain {
                try service.renameTagGroup(groupID: groupID, rawName: rawName)
            }
            guard let index = tagGroups.firstIndex(where: { $0.id == groupID }) else {
                notice = .tagMutationFailed
                return false
            }
            tagGroups[index] = renamed
            return true
        } catch {
            notice = tagGroupNotice(for: error)
            return false
        }
    }

    func deleteTagGroup(_ groupID: UUID) async -> Bool {
        let service = service
        do {
            notice = nil
            try await Self.offMain { try service.deleteTagGroup(groupID: groupID) }
            tagGroups.removeAll { $0.id == groupID }
            let fallback = TagGroupSeed.other.id
            tags = tags.map { tag in
                guard tag.groupID == groupID else { return tag }
                return TagListItem(
                    id: tag.id,
                    displayName: tag.displayName,
                    state: tag.state,
                    groupID: fallback
                )
            }
            return true
        } catch {
            notice = tagGroupNotice(for: error)
            return false
        }
    }

    private func reload(runPendingJobs: Bool) async {
        phase = .loading
        let service = service
        do {
            sources = try await Self.offMain { try service.fetchSources() }
            tags = try await Self.offMain { try service.listTags() }
            tagGroups = try await Self.offMain { try service.listTagGroups() }
        } catch {
            phase = .failed(.catalogFailed)
            return
        }

        guard !sources.isEmpty else {
            items = []
            nextCursor = nil
            phase = .empty
            return
        }

        await loadFirstPage()
        await refreshReviewState()
        if runPendingJobs {
            startCatalogReconcileRunnerIfNeeded()
            startPersonalizationRunnerIfNeeded()
        }
    }

    private func startCatalogReconcileRunnerIfNeeded(
        allowInLibrarySlimming: Bool = false
    ) {
        guard allowInLibrarySlimming || !isLibrarySlimmingWorkspaceActive else { return }
        catalogReconcileRunRequested = true
        guard catalogReconcileTask == nil else { return }
        let service = service
        let hasPendingWork = (try? service.hasPendingCatalogReconcileJobs()) ?? true
        guard hasPendingWork else {
            catalogReconcileRunRequested = false
            return
        }
        isCatalogScanning = true
        catalogReconcileTask = Task { [weak self] in
            guard let self else { return }
            let progressMonitor = Task { [weak self] in
                await self?.monitorCatalogReconcileProgress()
            }
            repeat {
                self.catalogReconcileRunRequested = false
                do {
                    // Keep catalog reconcile below interactive QoS so sidebar
                    // navigation and thumbnail reads stay responsive mid-scan.
                    try await Self.offMain(priority: .utility) {
                        try service.runPendingReconcileJobs()
                        try service.runPendingPhotosReconcileJobs()
                    }
                    if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                        self.sources = refreshed
                    }
                    await self.reloadLoadedAssetWindow()
                    await self.refreshReviewState()
                    self.startPersonalizationRunnerIfNeeded()
                } catch {
                    self.catalogReconcileRunRequested = false
                    if self.reportsLibrarySlimmingCatalogRefreshCompletion {
                        self.librarySlimmingStatusMessage = "照片来源刷新失败，请稍后重试"
                        self.reportsLibrarySlimmingCatalogRefreshCompletion = false
                    }
                    if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                        self.sources = refreshed
                    }
                    if self.sources.contains(where: { $0.kind == .photos && $0.state == .authorizationRequired }) {
                        self.phase = .content
                        self.notice = .photosAuthorizationRequired
                    } else if self.items.isEmpty {
                        self.phase = .failed(.scanFailed)
                    } else {
                        self.notice = .backgroundScanFailed
                    }
                }
            } while self.catalogReconcileRunRequested
            progressMonitor.cancel()
            await progressMonitor.value
            self.catalogReconcileProgress = nil
            self.catalogReconcileTask = nil
            if self.catalogReconcileRunRequested {
                self.startCatalogReconcileRunnerIfNeeded()
            } else {
                if case .failed = self.phase {
                    // Preserve the visible scan failure instead of letting a
                    // final empty-page refresh overwrite it with `.content`.
                } else {
                    await self.reloadLoadedAssetWindow()
                }
                self.isCatalogScanning = false
                if self.reportsLibrarySlimmingCatalogRefreshCompletion {
                    self.librarySlimmingStatusMessage = "照片来源已刷新"
                    self.reportsLibrarySlimmingCatalogRefreshCompletion = false
                }
            }
        }
    }

    private func monitorCatalogReconcileProgress() async {
        let service = service
        // Soft refresh for Photos *and* folder scans: keep retrying until the
        // first batch appears, then only occasionally append newer indexed
        // assets — never remount the LazyVGrid.
        var lastPublishedProgressCompleted = 0
        var lastSoftReloadAtCompleted = 0
        var publishedFirstBatch = !items.isEmpty
        var lastMonitoredSourceID = selectedSourceID
        var hadCatalogProgress = false
        var lastProgressSourceID: UUID?
        let softReloadStride = 64
        while !Task.isCancelled {
            if lastMonitoredSourceID != selectedSourceID {
                lastMonitoredSourceID = selectedSourceID
                lastPublishedProgressCompleted = 0
                lastSoftReloadAtCompleted = 0
                publishedFirstBatch = !items.isEmpty
            }
            if let progress = try? await Self.offMain({
                try service.fetchCatalogReconcileProgress()
            }) {
                catalogReconcileProgress = progress
                hadCatalogProgress = true
                lastProgressSourceID = progress.sourceID
                if isViewingCatalogProgressScope(progress), progress.completed > 0 {
                    let progressed = progress.completed > lastPublishedProgressCompleted
                    if progressed {
                        lastPublishedProgressCompleted = progress.completed
                    }
                    // Empty grid must keep retrying even when progress stalls,
                    // otherwise the first publish after a static progress tick is missed.
                    let waitingForFirstBatch = !publishedFirstBatch
                    let shouldSoftReload =
                        waitingForFirstBatch
                        || (progressed && progress.completed - lastSoftReloadAtCompleted >= softReloadStride)
                    if shouldSoftReload {
                        await loadFirstPage(remountGrid: false)
                        publishedFirstBatch = !items.isEmpty
                        if progressed {
                            lastSoftReloadAtCompleted = progress.completed
                        }
                    }
                }
            } else if hadCatalogProgress {
                hadCatalogProgress = false
                catalogReconcileProgress = nil
                if isViewingCompletedCatalogProgressScope(sourceID: lastProgressSourceID) {
                    await loadFirstPage(remountGrid: false)
                }
                lastProgressSourceID = nil
            }
            do {
                try await Task.sleep(for: catalogProgressRefreshInterval)
            } catch {
                return
            }
        }
    }

    /// Soft-reload only when the user is looking at the scanning scope (or "全部").
    private func isViewingCatalogProgressScope(_ progress: CatalogReconcileProgress) -> Bool {
        if selectedSourceID == nil {
            return true
        }
        switch progress.sourceKind {
        case .photos:
            return selectedSourceIsPhotos
        case .folder:
            if let scanningID = progress.sourceID {
                return selectedSourceID == scanningID
            }
            guard let selected = sources.first(where: { $0.id == selectedSourceID }) else {
                return false
            }
            return selected.displayName == progress.sourceDisplayName
        }
    }

    private func isViewingCompletedCatalogProgressScope(sourceID: UUID?) -> Bool {
        if selectedSourceID == nil {
            return true
        }
        if let sourceID {
            if let selected = sources.first(where: { $0.id == selectedSourceID }),
               selected.kind == .photos,
               let completed = sources.first(where: { $0.id == sourceID }),
               completed.kind == .photos
            {
                return true
            }
            return selectedSourceID == sourceID
        }
        return selectedSourceIsPhotos
    }

    private func loadFirstPage(remountGrid: Bool = true) async {
        let requestID = UUID()
        assetPageRequestID = requestID
        let service = service
        let filter = currentFilter
        let sort = sort
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: nil)
            }
            guard assetPageRequestID == requestID else { return }
            let visibleItems = page.items.filter {
                !hiddenRecycledAssetIDs.contains($0.assetID)
            }
            let refreshedItems: [AssetGridItemProjection]
            let refreshedCursor: AssetPageCursor?
            if remountGrid {
                refreshedItems = visibleItems
                refreshedCursor = page.nextCursor
            } else {
                // Progress polling is a soft refresh. It may run after the user
                // has paged far beyond the first 100 assets, so replacing the
                // grid here would collapse the visible window and strand the
                // LazyVGrid's already-completed pagination task.
                let firstPageIDs = Set(visibleItems.map(\.assetID))
                refreshedItems = visibleItems + items.filter {
                    !firstPageIDs.contains($0.assetID)
                        && !hiddenRecycledAssetIDs.contains($0.assetID)
                }
                refreshedCursor = nextCursor ?? page.nextCursor
            }
            if !remountGrid,
               refreshedItems == items,
               refreshedCursor == nextCursor
            {
                return
            }
            items = refreshedItems
            nextCursor = refreshedCursor
            if remountGrid {
                assetGridRevision += 1
            }
            let hadSelection = !selectedAssetIDs.isEmpty
            let visibleIDs = Set(refreshedItems.map(\.assetID))
            selectedAssetIDs.formIntersection(visibleIDs)
            resetCloudPreviewIfSelectionChanged()
            if selectedAssetIDs.isEmpty {
                isSinglePhotoPresented = false
                inspectorDetail = nil
                inspectorTags = []
                if hadSelection {
                    notice = .selectionHiddenByFilter
                }
            } else if selectedAssetIDs.count == 1,
                      let selectedAssetID = selectedAssetIDs.first,
                      inspectorDetail?.assetID != selectedAssetID
            {
                _ = await refreshInspector()
            }
            phase = .content
        } catch {
            guard assetPageRequestID == requestID else { return }
            phase = .failed(.catalogFailed)
        }
    }

    /// Reconciles the currently loaded pagination depth after a background
    /// source job completes. Unlike a first-page refresh, this preserves the
    /// user's scrollable window while also removing assets that no longer
    /// satisfy the active filter.
    private func reloadLoadedAssetWindow() async {
        let requestID = UUID()
        assetPageRequestID = requestID
        let service = service
        let filter = currentFilter
        let sort = sort
        let minimumItemCount = max(items.count, 1)
        do {
            let page = try await Self.offMain {
                try Self.fetchAssetWindow(
                    service: service,
                    filter: filter,
                    sort: sort,
                    minimumItemCount: minimumItemCount
                )
            }
            guard assetPageRequestID == requestID else { return }
            let visibleItems = page.items.filter {
                !hiddenRecycledAssetIDs.contains($0.assetID)
            }
            if visibleItems == items, page.nextCursor == nextCursor {
                return
            }
            items = visibleItems
            nextCursor = page.nextCursor
            let hadSelection = !selectedAssetIDs.isEmpty
            let visibleIDs = Set(visibleItems.map(\.assetID))
            selectedAssetIDs.formIntersection(visibleIDs)
            resetCloudPreviewIfSelectionChanged()
            if selectedAssetIDs.isEmpty {
                isSinglePhotoPresented = false
                inspectorDetail = nil
                inspectorTags = []
                if hadSelection {
                    notice = .selectionHiddenByFilter
                }
            } else if selectedAssetIDs.count == 1,
                      let selectedAssetID = selectedAssetIDs.first,
                      inspectorDetail?.assetID != selectedAssetID
            {
                _ = await refreshInspector()
            }
            phase = .content
        } catch {
            guard assetPageRequestID == requestID else { return }
            phase = .failed(.catalogFailed)
        }
    }

    nonisolated private static func fetchAssetWindow(
        service: any LibraryWorkspacePort,
        filter: AssetPageFilter,
        sort: AssetPageSort,
        minimumItemCount: Int
    ) throws -> AssetPageResult {
        var collected: [AssetGridItemProjection] = []
        var cursor: AssetPageCursor?
        repeat {
            let page = try service.fetchAssetPage(
                filter: filter,
                sort: sort,
                cursor: cursor
            )
            collected.append(contentsOf: page.items)
            let previousCursor = cursor
            cursor = page.nextCursor
            if page.items.isEmpty || cursor == previousCursor {
                cursor = nil
                break
            }
        } while cursor != nil && collected.count < minimumItemCount
        return AssetPageResult(items: collected, nextCursor: cursor)
    }

    func applySearchText(_ text: String) async {
        searchText = text
        await loadFirstPage()
    }

    func scheduleSearchText(_ text: String) {
        searchDebounceTask?.cancel()
        let interval = text.isEmpty ? Duration.zero : searchDebounceInterval
        searchDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.applySearchText(text)
        }
    }

    func submitSearchText(_ text: String) async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        await applySearchText(text)
    }

    func toggleAcceptedTagFilter(_ tagID: UUID) async {
        await toggleIncludedTagFilter(tagID, matchMode: .any)
    }

    func toggleIncludedTagFilter(_ tagID: UUID, matchMode: TagMatchMode = .any) async {
        excludedTagFilterIDs.remove(tagID)
        if selectedTagFilterDecisions[tagID] == .accepted {
            selectedTagFilterDecisions.removeValue(forKey: tagID)
            selectedTagFilterIDs.remove(tagID)
        } else {
            selectedTagFilterDecisions[tagID] = .accepted
            selectedTagFilterIDs.insert(tagID)
            tagPresence = .any
            // Mode follows the gesture that adds the tag: plain click = union,
            // ⌘-click = intersection. Removing a tag does not change mode.
            tagMatchMode = matchMode
        }
        await loadFirstPage()
    }

    func filterToSingleIncludedTag(_ tagID: UUID) async {
        selectedTagFilterDecisions = [tagID: .accepted]
        selectedTagFilterIDs = [tagID]
        excludedTagFilterIDs = []
        tagPresence = .any
        await loadFirstPage()
    }

    func clearTagFilters() async {
        guard hasActiveTagFilters else { return }
        selectedTagFilterDecisions = [:]
        selectedTagFilterIDs = []
        excludedTagFilterIDs = []
        await loadFirstPage()
    }

    func toggleExcludedTagFilter(_ tagID: UUID) async {
        selectedTagFilterDecisions.removeValue(forKey: tagID)
        selectedTagFilterIDs.remove(tagID)
        if excludedTagFilterIDs.contains(tagID) {
            excludedTagFilterIDs.remove(tagID)
        } else {
            excludedTagFilterIDs.insert(tagID)
            tagPresence = .any
        }
        await loadFirstPage()
    }

    func isTagFilterIncluded(_ tagID: UUID) -> Bool {
        selectedTagFilterDecisions[tagID] == .accepted
    }

    func isTagFilterExcluded(_ tagID: UUID) -> Bool {
        excludedTagFilterIDs.contains(tagID)
    }

    func setTagMatchMode(_ mode: TagMatchMode) async {
        tagMatchMode = mode
        await loadFirstPage()
    }

    func setTagPresence(_ presence: TagPresenceFilter) async {
        tagPresence = presence
        if presence != .any {
            selectedTagFilterDecisions = [:]
            selectedTagFilterIDs = []
            excludedTagFilterIDs = []
        }
        await loadFirstPage()
    }

    func setGridDensity(_ density: LibraryGridDensity) {
        gridDensity = density
    }

    func setThumbnailAspectMode(_ mode: LibraryThumbnailAspectMode) {
        thumbnailAspectMode = mode
    }

    func toggleAvailabilityFilter(_ availability: AssetAvailability) async {
        if let index = selectedAvailabilities.firstIndex(of: availability) {
            selectedAvailabilities.remove(at: index)
        } else {
            selectedAvailabilities.append(availability)
        }
        await loadFirstPage()
    }

    func clearAvailabilityFilters() async {
        guard !selectedAvailabilities.isEmpty else { return }
        selectedAvailabilities = []
        await loadFirstPage()
    }

    func toggleMediaTypeFilterGroup(_ mediaTypes: [String]) async {
        let mediaTypes = mediaTypes.filter { !$0.isEmpty }
        guard !mediaTypes.isEmpty else { return }

        if mediaTypes.allSatisfy(selectedMediaTypes.contains) {
            selectedMediaTypes.removeAll { mediaTypes.contains($0) }
        } else {
            for mediaType in mediaTypes where !selectedMediaTypes.contains(mediaType) {
                selectedMediaTypes.append(mediaType)
            }
        }
        await loadFirstPage()
    }

    func clearMediaTypeFilters() async {
        guard !selectedMediaTypes.isEmpty else { return }
        selectedMediaTypes = []
        await loadFirstPage()
    }

    func setMediaKind(_ mediaKind: MediaKind) async {
        guard selectedMediaKind != mediaKind else { return }
        assetPageRequestID = UUID()
        searchDebounceTask?.cancel()
        selectedMediaKind = mediaKind
        selectedMediaTypes = []
        selectedAssetIDs = []
        selectionAnchorID = nil
        isSinglePhotoPresented = false
        inspectorDetail = nil
        inspectorTags = []
        assetPendingSuggestions = []
        cloudPreviewState = .hidden
        if reviewMode != nil {
            reviewPageRequestID = UUID()
            reviewMode = .overview
            reviewQueueItems = []
            reviewNextCursor = nil
            selectedReviewItemID = nil
            suggestionOverviews = []
            pendingSuggestionTotal = 0
            await refreshReviewState()
            return
        }
        await loadFirstPage()
    }

    func clearAssetPropertyFilters() async {
        guard hasAssetPropertyFilters else { return }
        selectedAvailabilities = []
        selectedMediaTypes = []
        await loadFirstPage()
    }

    func isMediaTypeFilterGroupSelected(_ mediaTypes: [String]) -> Bool {
        !mediaTypes.isEmpty && mediaTypes.allSatisfy(selectedMediaTypes.contains)
    }

    func setSort(_ newSort: AssetPageSort) async {
        guard sort != newSort else { return }
        sort = newSort
        await loadFirstPage()
    }

    func setTagDecisionFilter(
        tagID: UUID,
        decision: PersistableTagDecision?
    ) async {
        selectedTagFilterDecisions[tagID] = decision
        selectedTagFilterIDs = Set(selectedTagFilterDecisions.keys)
        // Decision-panel include/reject must not leave the same tag excluded.
        excludedTagFilterIDs.remove(tagID)
        if decision != nil {
            tagPresence = .any
        }
        await loadFirstPage()
    }

    func showAcceptedTag(_ tagID: UUID) async {
        await filterToSingleIncludedTag(tagID)
    }

    func tagFilterDecision(for tagID: UUID) -> PersistableTagDecision? {
        selectedTagFilterDecisions[tagID]
    }

    private var currentFilter: AssetPageFilter {
        AssetPageFilter(
            sourceIDs: selectedSourceID.map { [$0] } ?? [],
            tagDecisionFilters: tags
                .filter { selectedTagFilterIDs.contains($0.id) }
                .compactMap { tag in
                    selectedTagFilterDecisions[tag.id].map {
                        TagDecisionFilter(tagID: tag.id, decision: $0)
                    }
                },
            excludedTagIDs: Array(excludedTagFilterIDs),
            tagMatchMode: tagMatchMode,
            availabilities: selectedAvailabilities,
            mediaKinds: [selectedMediaKind],
            mediaTypes: selectedMediaTypes,
            tagPresence: tagPresence,
            searchText: searchText
        )
    }

    func dismissNotice() {
        notice = nil
    }

    private func tagNotice(for error: Error) -> LibraryWorkspaceNotice {
        switch error as? CatalogQueryError {
        case .invalidTagName:
            .invalidTagName
        case .duplicateTag:
            .duplicateTag
        default:
            .tagMutationFailed
        }
    }

    private func tagGroupNotice(for error: Error) -> LibraryWorkspaceNotice {
        switch error as? CatalogQueryError {
        case .invalidTagName:
            .invalidTagGroupName
        case .duplicateTag:
            .duplicateTagGroup
        case .systemGroupProtected:
            .systemTagGroupProtected
        default:
            .tagMutationFailed
        }
    }

    private func mutationAffectsCurrentFilter(tagID: UUID) -> Bool {
        selectedTagFilterIDs.contains(tagID) ||
        excludedTagFilterIDs.contains(tagID) ||
        tagPresence != .any ||
        !TagNameNormalizer.trimUnicodeWhiteSpace(searchText).isEmpty
    }

    private func applyGridDecision(
        snapshot: TagMutationPriorStateSnapshot,
        newDecision: TagDecisionQueryState
    ) {
        for prior in snapshot.priorStates {
            replaceGridDecision(
                assetID: prior.assetID,
                oldDecision: prior.priorState,
                newDecision: newDecision
            )
        }
    }

    private func restoreGridDecision(_ undo: LibraryTagUndoRecord) {
        for prior in undo.snapshot.priorStates {
            replaceGridDecision(
                assetID: prior.assetID,
                oldDecision: undo.appliedDecision,
                newDecision: prior.priorState
            )
        }
    }

    private func replaceGridDecision(
        assetID: UUID,
        oldDecision: TagDecisionQueryState,
        newDecision: TagDecisionQueryState
    ) {
        guard let index = items.firstIndex(where: { $0.assetID == assetID }) else { return }
        switch oldDecision {
        case .accepted:
            items[index].acceptedTagCount = max(0, items[index].acceptedTagCount - 1)
        case .rejected:
            items[index].rejectedTagCount = max(0, items[index].rejectedTagCount - 1)
        case .unknown:
            break
        }
        switch newDecision {
        case .accepted:
            items[index].acceptedTagCount += 1
        case .rejected:
            items[index].rejectedTagCount += 1
        case .unknown:
            break
        }
    }


    @discardableResult
    private func refreshInspector() async -> Bool {
        resetCloudPreviewIfSelectionChanged()
        let assetIDs = Array(selectedAssetIDs)
        let selectionSnapshot = Set(assetIDs)
        guard !assetIDs.isEmpty else {
            inspectorDetail = nil
            inspectorTags = []
            assetPendingSuggestions = []
            return true
        }

        let service = service
        let reviewPort = review
        let availableTags = tags
        do {
            if assetIDs.count == 1, let assetID = assetIDs.first {
                let detail = try await Self.offMain(priority: .high) {
                    try service.fetchInspectorDetail(assetID: assetID)
                }
                let pending = try await Self.offMain(priority: .high) {
                    try reviewPort.pendingSuggestionsForAsset(assetID: assetID)
                }
                guard selectedAssetIDs == selectionSnapshot else { return false }
                inspectorDetail = detail
                inspectorTags = detail.tags
                    .filter { $0.tagState == .active }
                    .map {
                        LibraryInspectorTagPresentation(
                            id: $0.tagID,
                            displayName: $0.displayName,
                            decision: LibraryInspectorTagDecisionState($0.decision)
                        )
                    }
                assetPendingSuggestions = pending
            } else {
                let aggregates = try await Self.offMain {
                    try service.selectionAggregate(tagIDs: availableTags.map(\.id), assetIDs: assetIDs)
                }
                guard selectedAssetIDs == selectionSnapshot else { return false }
                let aggregateByTagID = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.tagID, $0) })
                inspectorDetail = nil
                assetPendingSuggestions = []
                inspectorTags = availableTags.compactMap { tag in
                    guard let aggregate = aggregateByTagID[tag.id] else { return nil }
                    let decision: LibraryInspectorTagDecisionState
                    if aggregate.acceptedCount == assetIDs.count {
                        decision = .accepted
                    } else if aggregate.rejectedCount == assetIDs.count {
                        decision = .rejected
                    } else if aggregate.unknownCount == assetIDs.count {
                        decision = .unknown
                    } else {
                        decision = .mixed
                    }
                    return LibraryInspectorTagPresentation(
                        id: tag.id,
                        displayName: tag.displayName,
                        decision: decision
                    )
                }
            }
            return true
        } catch {
            guard selectedAssetIDs == selectionSnapshot else { return false }
            inspectorDetail = nil
            inspectorTags = []
            assetPendingSuggestions = []
            return false
        }
    }

    private func restoreCommittedNewTagPresentation(
        _ result: TagCreateAndApplyResult,
        assetIDs: [UUID]
    ) {
        let committedAssetIDs = Set(assetIDs)
        guard !selectedAssetIDs.isEmpty,
              selectedAssetIDs.isSubset(of: committedAssetIDs)
        else {
            return
        }
        inspectorTags.append(
            LibraryInspectorTagPresentation(
                id: result.tagID,
                displayName: result.displayName,
                decision: .accepted
            )
        )
        inspectorTags.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func offMain<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: priority, operation: operation).value
    }

    /// Child task that cancels with the caller, unlike `offMain`'s detached work.
    private static func cancellableOffMain<T: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: priority) {
                try operation()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func resetCloudPreviewIfSelectionChanged() {
        guard cloudPreviewState.assetID != nil,
              cloudPreviewState.assetID != primarySelectedAssetID
        else {
            return
        }
        cancelCloudPreviewTask(resetToAvailable: false)
        cloudPreviewState = .hidden
    }

    private func resetLocalModelSuggestionsForSelection() {
        localModelSuggestionRequestID = nil
        localModelSuggestionTrack = .standard
        guard localModelSuggestions != nil,
              let assetID = primarySelectedAssetID
        else {
            localModelSuggestionState = .hidden
            return
        }
        localModelSuggestionState = .ready(assetID: assetID)
    }

    private func cancelCloudPreviewTask(resetToAvailable: Bool) {
        let assetID = cloudPreviewState.assetID
        cloudPreviewRequestID = nil
        cloudPreviewTask?.cancel()
        cloudPreviewTask = nil
        if resetToAvailable, let assetID {
            cloudPreviewState = .available(assetID: assetID)
        }
    }
}

extension LibraryWorkspaceModel {
    var isReviewMode: Bool { reviewMode != nil }

    var canUndoReviewMutation: Bool { lastReviewMutation != nil }

    var personalLibrarySuggestionJobActivity: JobActivityItem? {
        guard let personalLibrarySuggestionJobID else { return nil }
        return jobActivityItems.first { $0.id == personalLibrarySuggestionJobID }
    }

    var standardLibrarySuggestionJobActivity: JobActivityItem? {
        guard let standardLibrarySuggestionJobID else { return nil }
        return jobActivityItems.first { $0.id == standardLibrarySuggestionJobID }
    }

    func applyStandardLibrarySuggestionAction(_ action: JobActivityAction) async {
        guard let activity = standardLibrarySuggestionJobActivity,
              activity.availableActions.contains(action)
        else {
            return
        }
        await applyJobActivityAction(action, to: activity.id)
    }

    func applyPersonalLibrarySuggestionAction(_ action: JobActivityAction) async {
        guard let activity = personalLibrarySuggestionJobActivity,
              activity.availableActions.contains(action)
        else {
            return
        }
        await applyJobActivityAction(action, to: activity.id)
    }

    func refreshReviewState() async {
        let reviewPort = review
        let sourceFilter = resolvedReviewSourceFilter
        let mediaKind = selectedMediaKind
        do {
            pendingSuggestionTotal = try await Self.offMain {
                try reviewPort.totalPendingSuggestionCount(
                    mediaKind: mediaKind,
                    sourceIDs: sourceFilter
                )
            }
            suggestionOverviews = try await Self.offMain {
                try reviewPort.tagOverviews(
                    mediaKind: mediaKind,
                    sourceIDs: sourceFilter
                )
            }
            let personalJob = try await Self.offMain {
                try reviewPort.personalLibrarySuggestionJob(mediaKind: mediaKind)
            }
            if let personalJob {
                personalLibrarySuggestionJobID = personalJob.id
                personalLibrarySuggestionState = Self.personalLibraryPresentation(
                    for: personalJob
                )
            } else {
                personalLibrarySuggestionJobID = nil
                personalLibrarySuggestionState = .idle
            }
            let standardJob = try await Self.offMain {
                try reviewPort.standardLibrarySuggestionJob(mediaKind: mediaKind)
            }
            if let standardJob {
                standardLibrarySuggestionJobID = standardJob.id
                standardLibrarySuggestionState = Self.standardLibraryPresentation(
                    for: standardJob
                )
            } else {
                standardLibrarySuggestionJobID = nil
                standardLibrarySuggestionState = .idle
            }
            if reviewMode == .overview {
                let service = service
                if let activity = try? await Self.offMain({
                    try service.fetchJobActivity()
                }) {
                    jobActivityItems = activity
                }
            }
            if case let .tagQueue(tagID, _) = reviewMode {
                await loadReviewQueueFirstPage(tagID: tagID)
            }
            if let assetID = primarySelectedAssetID, reviewMode == nil {
                assetPendingSuggestions = try await Self.offMain {
                    try reviewPort.pendingSuggestionsForAsset(assetID: assetID)
                }
            } else {
                assetPendingSuggestions = []
            }
        } catch {
            suggestionOverviews = []
            pendingSuggestionTotal = 0
        }
    }

    private static func personalLibraryPresentation(
        for job: PersonalLibrarySuggestionJobProjection
    ) -> PersonalLibrarySuggestionPresentationState {
        let counts = (
            checked: job.checkedCount,
            suggested: job.suggestedCount,
            skipped: job.skippedCount
        )
        switch job.state {
        case .pending:
            return .waiting(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .running:
            return .running(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .paused:
            return .paused(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .retryableFailed:
            return .retryableFailure(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .completed:
            return .completed(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .cancelled:
            return .cancelled(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .terminalFailed:
            return job.lastErrorCode == .personalLibraryBundleUnavailable
                ? .personalUnavailable
                : .failed
        }
    }

    private static func standardLibraryPresentation(
        for job: StandardLibrarySuggestionJobProjection
    ) -> StandardLibrarySuggestionPresentationState {
        let counts = (
            checked: job.checkedCount,
            suggested: job.suggestedCount,
            skipped: job.skippedCount
        )
        switch job.state {
        case .pending:
            return .waiting(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .running:
            return .running(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .paused:
            return .paused(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .retryableFailed:
            return .retryableFailure(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .completed:
            return .completed(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .cancelled:
            return .cancelled(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .terminalFailed:
            return .failed
        }
    }

    /// Applies review/gallery presentation synchronously so sidebar navigation
    /// never renders the photo grid for one frame before async work completes.
    func applyImmediateBrowsingPresentation(for destination: LibraryBrowsingDestination) {
        setLibrarySlimmingWorkspaceActive(destination == .librarySlimming)
        switch destination {
        case .reviewSuggestions:
            selectedMediaKind = .image
            applyReviewOverviewPresentation()
        case .trainingWorkspace, .librarySlimming:
            selectedMediaKind = .image
            clearReviewModeState()
            isSinglePhotoPresented = false
        case .all, .untagged, .source:
            clearReviewModeState()
            applyGalleryBrowsingFilters(for: destination)
            // Drop stale gallery rows so the previous filter cannot paint under
            // the newly selected sidebar destination before loadFirstPage.
            items = []
            nextCursor = nil
            selectedAssetIDs = []
            isSinglePhotoPresented = false
            inspectorDetail = nil
            inspectorTags = []
        }
    }

    func enterReviewOverview() async {
        applyReviewOverviewPresentation()
        await refreshReviewState()
    }

    private func applyReviewOverviewPresentation() {
        reviewPageRequestID = UUID()
        reviewMode = .overview
        selectedAssetIDs = []
        selectedReviewItemID = nil
        isSinglePhotoPresented = false
    }

    private func applyGalleryBrowsingFilters(for destination: LibraryBrowsingDestination) {
        switch destination {
        case .all:
            selectedSourceID = nil
            tagPresence = .any
        case .untagged:
            selectedSourceID = nil
            tagPresence = .untagged
            selectedTagFilterDecisions = [:]
            selectedTagFilterIDs = []
            excludedTagFilterIDs = []
        case let .source(sourceID):
            selectedSourceID = sourceID
            tagPresence = .any
        case .reviewSuggestions, .trainingWorkspace, .librarySlimming:
            break
        }
    }

    func enterReviewQueue(tagID: UUID, displayName: String) async {
        reviewPageRequestID = UUID()
        reviewQueueItems = []
        reviewNextCursor = nil
        selectedAssetIDs = []
        selectedReviewItemID = nil
        isSinglePhotoPresented = false
        reviewMode = .tagQueue(tagID: tagID, displayName: displayName)
        // Let the overview List finish tearing down before the first review-grid layout pass.
        await Task.yield()
        await loadReviewQueueFirstPage(tagID: tagID)
    }

    func exitReviewMode() async {
        clearReviewModeState()
        await loadFirstPage()
        await refreshReviewState()
    }

    private func clearReviewModeState() {
        reviewPageRequestID = UUID()
        reviewMode = nil
        reviewQueueItems = []
        selectedReviewItemID = nil
        reviewNextCursor = nil
    }

    func loadReviewQueueFirstPage(tagID: UUID) async {
        let requestID = UUID()
        reviewPageRequestID = requestID
        let reviewPort = review
        let sourceFilter = resolvedReviewSourceFilter
        let mediaKind = selectedMediaKind
        do {
            let page = try await Self.offMain {
                try reviewPort.fetchReviewQueue(
                    mediaKind: mediaKind,
                    tagID: tagID,
                    sourceIDs: sourceFilter,
                    cursor: nil,
                    limit: 100
                )
            }
            guard reviewPageRequestID == requestID else { return }
            reviewQueueItems = page.items.filter {
                !hiddenRecycledAssetIDs.contains($0.assetID)
            }
            if let selectedReviewItemID,
               !reviewQueueItems.contains(where: { $0.id == selectedReviewItemID })
            {
                if selectedAssetIDs.count == 1,
                   let selectedAssetID = selectedAssetIDs.first,
                   let replacement = reviewQueueItems.first(where: {
                       $0.assetID == selectedAssetID
                   })
                {
                    self.selectedReviewItemID = replacement.id
                } else {
                    self.selectedReviewItemID = nil
                    selectedAssetIDs = []
                    isSinglePhotoPresented = false
                }
            }
            reviewNextCursor = page.nextCursor
        } catch {
            guard reviewPageRequestID == requestID else { return }
            reviewQueueItems = []
            selectedReviewItemID = nil
            reviewNextCursor = nil
        }
    }

    func loadMoreReviewQueueIfNeeded(currentAssetID: UUID, tagID: UUID) async {
        guard currentAssetID == reviewQueueItems.last?.assetID,
              let cursor = reviewNextCursor,
              !isLoadingMoreReviewQueue
        else { return }
        isLoadingMoreReviewQueue = true
        defer { isLoadingMoreReviewQueue = false }
        let requestID = reviewPageRequestID
        let reviewPort = review
        let sourceFilter = resolvedReviewSourceFilter
        let mediaKind = selectedMediaKind
        do {
            let page = try await Self.offMain {
                try reviewPort.fetchReviewQueue(
                    mediaKind: mediaKind,
                    tagID: tagID,
                    sourceIDs: sourceFilter,
                    cursor: cursor,
                    limit: 100
                )
            }
            guard reviewPageRequestID == requestID else { return }
            reviewQueueItems.append(
                contentsOf: page.items.filter {
                    !hiddenRecycledAssetIDs.contains($0.assetID)
                }
            )
            reviewNextCursor = page.nextCursor
        } catch {}
    }

    var activeReviewSources: [LibrarySourceSummary] {
        sources.filter { $0.state == .active }
    }

    /// `nil` means no source filter (all active). Empty array means match nothing.
    var resolvedReviewSourceFilter: [UUID]? {
        guard let selected = reviewFilterSourceIDs else { return nil }
        let activeIDs = activeReviewSources.map(\.id)
        return activeIDs.filter(selected.contains)
    }

    var reviewSourceFilterSummaryText: String {
        let active = activeReviewSources
        guard let selected = reviewFilterSourceIDs else {
            return "显示全部 \(active.count) 个来源的待审核建议"
        }
        let names = active.filter { selected.contains($0.id) }.map(\.displayName)
        if names.isEmpty {
            return "未选择来源，待审核列表为空"
        }
        if names.count == active.count {
            return "显示全部 \(active.count) 个来源的待审核建议"
        }
        return "仅显示：\(names.joined(separator: "、"))"
    }

    func isReviewSourceIncluded(_ sourceID: UUID) -> Bool {
        guard let selected = reviewFilterSourceIDs else { return true }
        return selected.contains(sourceID)
    }

    func setReviewSourceIncluded(_ sourceID: UUID, _ included: Bool) async {
        let activeIDs = Set(activeReviewSources.map(\.id))
        guard activeIDs.contains(sourceID) else { return }
        var selected = reviewFilterSourceIDs ?? activeIDs
        if included {
            selected.insert(sourceID)
        } else {
            selected.remove(sourceID)
        }
        selected.formIntersection(activeIDs)
        reviewFilterSourceIDs = selected == activeIDs ? nil : selected
        await refreshReviewState()
    }

    func selectAllReviewSources() async {
        reviewFilterSourceIDs = nil
        await refreshReviewState()
    }

    func toggleSuggestionEnqueueSource(_ sourceID: UUID) {
        guard var pending = pendingSuggestionConfirmation else { return }
        if pending.selectedSourceIDs.contains(sourceID) {
            pending.selectedSourceIDs.remove(sourceID)
        } else {
            pending.selectedSourceIDs.insert(sourceID)
        }
        pendingSuggestionConfirmation = pending
    }

    func moveReviewPrimarySelection(
        in direction: LibraryGridNavigationDirection,
        columnCount: Int
    ) async {
        guard case let .tagQueue(tagID, _) = reviewMode else { return }
        guard let currentItemID = selectedReviewItemID else {
            guard let firstItemID = reviewQueueItems.first?.id else { return }
            await selectReviewItem(firstItemID)
            return
        }

        let columns = max(columnCount, 1)
        let offset = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }

        if offset > 0,
           let currentIndex = reviewQueueItems.firstIndex(where: { $0.id == currentItemID }),
           currentIndex + offset >= reviewQueueItems.count,
           let lastLoadedID = reviewQueueItems.last?.assetID
        {
            await loadMoreReviewQueueIfNeeded(
                currentAssetID: lastLoadedID,
                tagID: tagID
            )
        }

        guard let currentIndex = reviewQueueItems.firstIndex(where: { $0.id == currentItemID }) else {
            return
        }
        let targetIndex = min(max(currentIndex + offset, 0), reviewQueueItems.count - 1)
        guard targetIndex != currentIndex else { return }
        await selectReviewItem(reviewQueueItems[targetIndex].id)
    }

    func moveReviewPrimarySelection(
        byPage direction: LibraryGridPageDirection,
        pageItemCount: Int
    ) async {
        let distance = max(pageItemCount, 1)
        await moveReviewPrimarySelection(
            in: direction == .down ? .right : .left,
            columnCount: distance
        )
    }

    func requestEnqueueSuggestions(
        tagID: UUID,
        displayName: String,
        mode: PersonalizationReviewEnqueueMode,
        method: SuggestionGenerationMethod = .featureKnn
    ) {
        let available = activeReviewSources.map {
            SuggestionEnqueueSourceOption(id: $0.id, displayName: $0.displayName)
        }
        guard !available.isEmpty else { return }
        let selected: Set<UUID>
        if let filter = reviewFilterSourceIDs {
            let availableIDs = Set(available.map(\.id))
            let intersection = filter.intersection(availableIDs)
            selected = intersection.isEmpty ? availableIDs : intersection
        } else {
            selected = Set(available.map(\.id))
        }
        pendingSuggestionConfirmation = SuggestionEnqueueConfirmation(
            tagID: tagID,
            mediaKind: selectedMediaKind,
            displayName: displayName,
            mode: mode,
            method: method,
            availableSources: available,
            selectedSourceIDs: selected,
            effectiveMinScore: effectiveSuggestionMinScore(
                tagID: tagID,
                method: method.thresholdMethod
            ),
            maxPendingSuggestionsPerTag: maxPendingSuggestionsPerTag
        )
    }

    func confirmPendingSuggestionEnqueue(
        _ capturedConfirmation: SuggestionEnqueueConfirmation? = nil
    ) async -> Bool {
        guard let pending = capturedConfirmation ?? pendingSuggestionConfirmation else {
            return false
        }
        guard pending.canStart else { return false }
        pendingSuggestionConfirmation = nil
        let selectedSourceIDs = Array(pending.selectedSourceIDs).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        switch pending.method {
        case .featureKnn:
            let reviewPort = review
            do {
                notice = nil
                let jobID = try await Self.offMain {
                    try reviewPort.enqueueFullLibrarySuggestions(
                        mediaKind: pending.mediaKind,
                        tagID: pending.tagID,
                        mode: pending.mode,
                        sourceIDs: selectedSourceIDs
                    )
                }
                featureSuggestionCompletionContexts[jobID] = FeatureSuggestionCompletionContext(
                    tagID: pending.tagID,
                    displayName: pending.displayName
                )
                startPersonalizationRunnerIfNeeded()
                await refreshReviewState()
                await refreshTrainingWorkspace(presentation: .automatic)
                return true
            } catch let error as PersonalizationReviewError {
                notice = reviewNotice(for: error)
                return false
            } catch {
                notice = .reviewActionFailed
                return false
            }
        case .personalModel:
            await generateAppPersonalTagLibrarySuggestions(
                tagID: pending.tagID,
                displayName: pending.displayName,
                sourceIDs: selectedSourceIDs,
                method: .personalModel
            )
            if case let .personalTagLibrarySuggestionsCompleted(_, _, _, inserted, _) = notice {
                if inserted > 0, reviewMode == .overview {
                    await enterReviewQueue(
                        tagID: pending.tagID,
                        displayName: pending.displayName
                    )
                }
                return true
            }
            return false
        case .personalAdamW:
            await generateAppPersonalTagLibrarySuggestions(
                tagID: pending.tagID,
                displayName: pending.displayName,
                sourceIDs: selectedSourceIDs,
                method: .personalAdamW
            )
            if case let .personalAdamWTagLibrarySuggestionsCompleted(_, _, _, inserted, _) = notice {
                if inserted > 0, reviewMode == .overview {
                    await enterReviewQueue(
                        tagID: pending.tagID,
                        displayName: pending.displayName
                    )
                }
                return true
            }
            return false
        }
    }

    func cancelPendingSuggestionEnqueue() {
        pendingSuggestionConfirmation = nil
    }

    private func startPersonalizationRunnerIfNeeded() {
        guard personalizationRunnerTask == nil else { return }
        let reviewPort = review
        let worker = PersonalizationSuggestionRunner.startLoop(review: reviewPort) { [weak self] in
            guard let self else { return }
            await self.refreshReviewState()
            await self.refreshTrainingWorkspace(presentation: .automatic)
            await self.refreshFeatureSuggestionCompletionNotices()
            if case let .tagQueue(tagID, _) = self.reviewMode {
                await self.loadReviewQueueFirstPage(tagID: tagID)
            }
        }
        personalizationRunnerTask = Task { [weak self] in
            await worker.value
            guard let self else { return }
            await self.refreshFeatureSuggestionCompletionNotices()
            self.personalizationRunnerTask = nil
        }
    }

    private func refreshFeatureSuggestionCompletionNotices() async {
        let pendingContexts = featureSuggestionCompletionContexts
        guard !pendingContexts.isEmpty else { return }
        let reviewPort = review
        for (jobID, context) in pendingContexts {
            guard let completion = try? await Self.offMain({
                try reviewPort.featureSuggestionJob(jobID: jobID)
            }) else {
                continue
            }
            switch completion.state {
            case .completed:
                let pendingCount = suggestionOverviews.first(where: {
                    $0.id == context.tagID
                })?.pendingSuggestionCount ?? 0
                notice = .featureKnnSuggestionsCompleted(
                    tagName: context.displayName,
                    candidates: completion.candidateCount,
                    aboveThreshold: completion.aboveThresholdCount,
                    reviewable: pendingCount,
                    skipped: completion.skippedCount
                )
                featureSuggestionCompletionContexts.removeValue(forKey: jobID)
                if pendingCount > 0, reviewMode == .overview {
                    await enterReviewQueue(
                        tagID: context.tagID,
                        displayName: context.displayName
                    )
                }
            case .terminalFailed, .cancelled:
                featureSuggestionCompletionContexts.removeValue(forKey: jobID)
            case .pending, .running, .paused, .retryableFailed:
                break
            }
        }
    }

    private func enqueueAutomaticPersonalModelRebuildIfReady() async {
        guard localModelSuggestions != nil else { return }
        let reviewPort = review
        do {
            let jobID = try await Self.offMain {
                try reviewPort.enqueuePersonalModelRebuildIfReady()
            }
            if jobID != nil {
                startPersonalizationRunnerIfNeeded()
            }
        } catch {
            // Automatic retraining is best-effort; manual rebuild remains available.
        }
    }

    func enqueueSuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) async -> Bool {
        guard let overview = suggestionOverviews.first(where: { $0.id == tagID }) else { return false }
        requestEnqueueSuggestions(
            tagID: tagID,
            displayName: overview.displayName,
            mode: mode
        )
        return true
    }

    func pauseSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.pauseSuggestionJob(jobID: jobID) }
        await refreshReviewState()
    }

    func resumeSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.resumeSuggestionJob(jobID: jobID) }
        startPersonalizationRunnerIfNeeded()
        await refreshReviewState()
    }

    func cancelSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.cancelSuggestionJob(jobID: jobID) }
        await refreshReviewState()
    }

    func applyReviewDecision(action: LibraryTagDecisionAction) async {
        guard case let .tagQueue(tagID, displayName) = reviewMode else { return }
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else { return }
        let workspace = service
        do {
            notice = nil
            let snapshot = try await Self.offMain {
                try workspace.mutateTag(tagID: tagID, assetIDs: assetIDs, action: action)
            }
            lastReviewMutation = ReviewMutationUndoRecord(
                snapshot: snapshot,
                appliedDecision: action.decision,
                tagDisplayName: displayName,
                affectedCount: assetIDs.count
            )
            notice = .reviewMutationApplied(count: assetIDs.count, tagName: displayName)
            let queueBefore = reviewQueueItems
            let selected = selectedAssetIDs
            let selectedRow = selectedReviewItemID
            reviewQueueItems.removeAll { selected.contains($0.assetID) }
            if let next = Self.nextReviewQueueSelection(
                in: reviewQueueItems,
                afterRemoving: selected,
                from: queueBefore,
                selectedRow: selectedRow
            ) {
                selectedReviewItemID = next
                selectedAssetIDs = [next.assetID]
            } else {
                selectedReviewItemID = nil
                selectedAssetIDs = []
                isSinglePhotoPresented = false
            }
            await enqueueAutomaticPersonalModelRebuildIfReady()
            await refreshReviewState()
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
        }
    }

    func deferReviewSelection() async {
        guard case .tagQueue = reviewMode,
              let selectedReviewItemID,
              !reviewQueueItems.isEmpty
        else { return }
        if let next = Self.deferredReviewSelection(
            in: reviewQueueItems,
            selectedRow: selectedReviewItemID
        ) {
            await selectReviewItem(next)
        }
    }

    private static func deferredReviewSelection(
        in queue: [ReviewQueueItemProjection],
        selectedRow: ReviewQueueItemID
    ) -> ReviewQueueItemID? {
        guard let selectedIndex = queue.firstIndex(where: { $0.id == selectedRow })
        else { return nil }
        let nextIndex = queue.index(after: selectedIndex)
        return nextIndex < queue.endIndex ? queue[nextIndex].id : queue.first?.id
    }

    private static func nextReviewQueueSelection(
        in queue: [ReviewQueueItemProjection],
        afterRemoving selected: Set<UUID>,
        from original: [ReviewQueueItemProjection],
        selectedRow: ReviewQueueItemID?
    ) -> ReviewQueueItemID? {
        if let selectedRow,
           let selectedIndex = original.firstIndex(where: { $0.id == selectedRow }),
           let next = original.dropFirst(selectedIndex + 1).first(where: { candidate in
               !selected.contains(candidate.assetID)
                   && queue.contains(where: { $0.id == candidate.id })
           }),
           queue.contains(where: { $0.id == next.id })
        {
            return next.id
        }
        guard let lastSelectedIndex = original.enumerated()
            .filter({ selected.contains($0.element.assetID) })
            .map(\.offset)
            .max()
        else { return queue.first?.id }

        if let next = original.enumerated()
            .first(where: { $0.offset > lastSelectedIndex && !selected.contains($0.element.assetID) })?
            .element.id,
            queue.contains(where: { $0.id == next })
        {
            return next
        }
        return queue.first?.id
    }

    func undoLastReviewMutation() async {
        guard let undo = lastReviewMutation else { return }
        let workspace = service
        do {
            notice = nil
            try await Self.offMain { try workspace.restoreTagMutation(undo.snapshot) }
            lastReviewMutation = nil
            await enqueueAutomaticPersonalModelRebuildIfReady()
            if case let .tagQueue(tagID, _) = reviewMode {
                await loadReviewQueueFirstPage(tagID: tagID)
            }
            await refreshReviewState()
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
        }
    }

    func applyInspectorSuggestion(tagID: UUID, action: LibraryTagDecisionAction) async {
        guard let assetID = primarySelectedAssetID else { return }
        let workspace = service
        do {
            notice = nil
            _ = try await Self.offMain {
                try workspace.mutateTag(tagID: tagID, assetIDs: [assetID], action: action)
            }
            assetPendingSuggestions.removeAll { $0.tagID == tagID }
            await enqueueAutomaticPersonalModelRebuildIfReady()
            await refreshInspector()
            await refreshReviewState()
        } catch {
            notice = .tagMutationFailed
        }
    }

    private func reviewNotice(for error: PersonalizationReviewError) -> LibraryWorkspaceNotice {
        switch error {
        case let .insufficientSamples(positive, negative):
            .insufficientSuggestionSamples(positiveMissing: positive, negativeMissing: negative)
        case .activeJobConflict:
            .reviewJobConflict
        default:
            .reviewActionFailed
        }
    }

#if DEBUG
    var selectionAnchorIDForTesting: UUID? { selectionAnchorID }
#endif
}

private enum LibrarySidebarSelection: Hashable {
    case all
    case untagged
    case reviewSuggestions
    case trainingWorkspace
    case librarySlimming
    case source(UUID)
}

private enum LibraryWorkspaceSheet: String, Identifiable {
    case commandPalette
    case keyboardShortcuts

    var id: String { rawValue }
}

private struct LibraryMediaFormatFilterOption {
    let title: String
    let mediaTypes: [String]
}

private struct LibraryTagFlowLayout: Layout {
    let horizontalSpacing: CGFloat = 6
    let verticalSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(
            width: proposal.width ?? usedWidth,
            height: subviews.isEmpty ? 0 : y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct LibrarySourceRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct LibraryTagChipFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct LibraryTagGroupContainerFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct LibrarySlimmingIdenticalCleanupBlockingOverlay: View {
    let progress: LibrarySlimmingIdenticalCleanupExecutionProgress

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Rectangle()
                .fill(Color.black.opacity(0.12))

            VStack(spacing: 18) {
                Image(systemName: phaseSystemImage)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 58, height: 58)
                    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 7) {
                    Text("正在优先执行一键清理")
                        .font(.title2.weight(.semibold))
                    Text(phaseTitle)
                        .font(.headline)
                    Text(phaseDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if progress.phase == .recyclingAssets, progress.totalAssetCount > 0 {
                    VStack(spacing: 7) {
                        ProgressView(
                            value: Double(progress.completedAssetCount),
                            total: Double(progress.totalAssetCount)
                        )
                        Text(
                            "已处理 \(progress.completedAssetCount.formatted()) / "
                                + "\(progress.totalAssetCount.formatted()) 张"
                        )
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.large)
                }

                Label("为避免删除冲突，其他操作已暂时锁定", systemImage: "lock.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                Text("请等待删除与删除后核验完成，不要退出 ImageAll。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("librarySlimmingIdenticalCleanupBlockingProgress")
        .accessibilityLabel(
            progress.phase == .recyclingAssets
                ? "\(phaseTitle)，已处理 \(progress.completedAssetCount) / "
                    + "\(progress.totalAssetCount) 张，其他操作已锁定"
                : "\(phaseTitle)，其他操作已锁定"
        )
    }

    private var phaseTitle: String {
        switch progress.phase {
        case .validatingPlan:
            "正在复核清理方案"
        case .recyclingAssets:
            "正在移入回收站"
        case .requestingAuthorization:
            "正在等待系统授权"
        case .refreshingState:
            "正在刷新删除状态"
        case .verifyingResult:
            "正在进行删除后核验"
        }
    }

    private var phaseDetail: String {
        switch progress.phase {
        case .validatingPlan:
            "重新读取照片与来源状态，确认清理范围没有变化。"
        case .recyclingAssets:
            "按已确认的优先级逐项处理；这里显示本次运行的实际进度。"
        case .requestingAuthorization:
            "如有系统窗口，请先完成照片或文件夹访问授权。"
        case .refreshingState:
            "重新读取回收记录和当前可用状态。"
        case .verifyingResult:
            "实打实统计已完成去重、仍有冗余和状态待确认的照片。"
        }
    }

    private var phaseSystemImage: String {
        switch progress.phase {
        case .validatingPlan:
            "checkmark.shield"
        case .recyclingAssets:
            "trash.square.fill"
        case .requestingAuthorization:
            "lock.open"
        case .refreshingState:
            "arrow.clockwise"
        case .verifyingResult:
            "checkmark.seal"
        }
    }
}

struct LibraryWorkspaceView: View {
    @EnvironmentObject private var toolbarDisplayModeSettings: ToolbarDisplayModeSettingsModel
    private static let sourceDropRowHeight: CGFloat = 40
    private static let sourceReorderCoordinateSpace = "library-source-reorder"
    private static let mediaFormatFilterOptions = [
        LibraryMediaFormatFilterOption(title: "JPEG", mediaTypes: [UTType.jpeg.identifier]),
        LibraryMediaFormatFilterOption(title: "PNG", mediaTypes: [UTType.png.identifier]),
        LibraryMediaFormatFilterOption(
            title: "HEIC / HEIF",
            mediaTypes: [UTType.heic.identifier, UTType.heif.identifier]
        ),
        LibraryMediaFormatFilterOption(title: "TIFF", mediaTypes: [UTType.tiff.identifier]),
        LibraryMediaFormatFilterOption(title: "WebP", mediaTypes: [UTType.webP.identifier]),
        LibraryMediaFormatFilterOption(title: "JPEG 2000", mediaTypes: [ApprovedSourceMediaTypes.jpeg2000Identifier]),
        LibraryMediaFormatFilterOption(title: "GIF", mediaTypes: [UTType.gif.identifier]),
        LibraryMediaFormatFilterOption(
            title: "RAW",
            mediaTypes: [
                ApprovedSourceMediaTypes.fujiRawIdentifier,
                ApprovedSourceMediaTypes.adobeRawIdentifier,
                "public.camera-raw-image",
            ]
        ),
    ]

    @ObservedObject var model: LibraryWorkspaceModel
    @State private var selection: LibrarySidebarSelection? = .all
    @State private var searchText = ""
    @State private var newTagName = ""
    @State private var sourcePendingDisable: LibrarySourceSummary?
    @State private var photosSourcePendingRebind: LibrarySourceSummary?
    @State private var photosSourcePendingFullRepair: LibrarySourceSummary?
    @State private var tagPendingRename: TagListItem?
    @State private var renamedTagName = ""
    @State private var tagPendingArchive: TagListItem?
    @State private var tagGroupPendingRename: TagGroupListItem?
    @State private var renamedTagGroupName = ""
    @State private var tagGroupPendingDelete: TagGroupListItem?
    @State private var showCreateTagGroupAlert = false
    @State private var newTagGroupName = ""
    @State private var tagDropTargetGroupID: UUID?
    @State private var showPhotosConnectionExplanation = false
    @State private var showPreviewCachePanel = false
    @State private var showPreviewCacheClearConfirmation = false
    @State private var showPhotosOriginalStorageClearConfirmation = false
    @State private var showJobActivityPanel = false
    @State private var activeSheet: LibraryWorkspaceSheet?
    @State private var commandSearchText = ""
    @State private var gridColumnCount = 1
    @State private var gridPageItemCount = 1
    @State private var gridCellFrames = LibraryGridCellFrameStore()
    @State private var sourceRowFrames: [UUID: CGRect] = [:]
    @State private var draggedSourceID: UUID?
    @State private var sourceInsertionOffset: Int?
    @State private var draggedTagID: UUID?
    @State private var draggedTagGroupID: UUID?
    @State private var tagChipFrames: [UUID: CGRect] = [:]
    @State private var tagGroupContainerFrames: [UUID: CGRect] = [:]
    @State private var tagInsertionGroupID: UUID?
    @State private var tagInsertionOffset: Int?
    @State private var isMarqueeSelecting = false
    @State private var gridScrollTargetID: UUID?
    @State private var layoutState = LibraryWorkspaceLayoutState()
    @FocusState private var newTagFieldFocused: Bool
    @FocusState private var contentFocused: Bool
    @FocusState private var commandSearchFieldFocused: Bool

    private var workspaceWithSourceControls: some View {
        NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            keyboardEnabledContent
        }
        .inspector(isPresented: inspectorVisibility) {
            workspaceInspector
                .inspectorColumnWidth(min: 240, ideal: 300, max: 380)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        layoutState.updateWindowWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        layoutState.updateWindowWidth(width)
                    }
            }
        }
        .sheet(
            item: Binding(
                get: { model.pendingSuggestionConfirmation },
                set: { model.pendingSuggestionConfirmation = $0 }
            )
        ) { pending in
            SuggestionEnqueueConfirmationSheet(model: model, pending: pending)
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索文件名、路径、标签或来源"
        )
        .onSubmit(of: .search) {
            Task { await model.submitSearchText(searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            model.scheduleSearchText(newValue)
        }
        .toolbar {
            ToolbarItemGroup {
                libraryToolbarLayoutItems
                libraryToolbarPersonalizationItems
                libraryToolbarBrowseAndActionItems
            }
        }
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = model.notice {
                noticeBar(notice)
            }
        }
        .confirmationDialog(
            sourcePendingDisable.map { "停用“\($0.displayName)”来源？" } ?? "停用来源？",
            isPresented: Binding(
                get: { sourcePendingDisable != nil },
                set: { if !$0 { sourcePendingDisable = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourcePendingDisable
        ) { source in
            Button("停用来源", role: .destructive) {
                sourcePendingDisable = nil
                Task { await model.disableSource(source.id) }
            }
            .persistentHelp("停止扫描这个来源，但保留索引、人工标签和历史；不会修改原照片。")
            Button("取消", role: .cancel) {
                sourcePendingDisable = nil
            }
            .persistentHelp("关闭确认窗口并保持来源启用。")
        } message: { _ in
            Text("ImageAll 会停止该来源的扫描任务，但保留已索引的照片、人工标签和历史；原照片不会被修改。")
        }
        .confirmationDialog(
            "连接当前系统照片图库？",
            isPresented: Binding(
                get: { photosSourcePendingRebind != nil },
                set: { if !$0 { photosSourcePendingRebind = nil } }
            ),
            titleVisibility: .visible,
            presenting: photosSourcePendingRebind
        ) { source in
            Button("保留历史并连接") {
                photosSourcePendingRebind = nil
                Task { await model.rebindPhotos(from: source.id) }
            }
            .persistentHelp("保留旧图库历史，并把当前系统照片图库连接为一个新的独立来源。")
            Button("取消", role: .cancel) {
                photosSourcePendingRebind = nil
            }
            .persistentHelp("关闭确认窗口，不连接当前系统照片图库。")
        } message: { _ in
            Text("ImageAll 会保留旧图库的索引、人工标签和历史，并为当前系统照片图库创建一个新的来源。不会迁移或合并无法确认身份的照片，也不会修改 Apple Photos 中的原图。")
        }
        .confirmationDialog(
            "连接 Apple Photos？",
            isPresented: $showPhotosConnectionExplanation,
            titleVisibility: .visible
        ) {
            Button("继续并请求照片权限") {
                Task { await model.connectPhotos() }
            }
            .persistentHelp("向 macOS 请求照片访问权限，并在授权后连接系统照片图库。")
            Button("取消", role: .cancel) {}
                .persistentHelp("关闭说明窗口，不请求照片访问权限。")
        } message: {
            Text("ImageAll 平时只读访问静态照片和元数据，在自身容器保存索引、标签和缓存；只有你在“图库瘦身”中明确确认时，才会经系统 Photos 将所选照片移入“最近删除”。普通浏览不会自动下载 iCloud 原图；“相同”检测需要时会下载并长期保留 App 自有副本。")
        }
        .confirmationDialog(
            photosSourcePendingFullRepair.map { "对“\($0.displayName)”执行完整修复扫描？" } ?? "完整修复扫描？",
            isPresented: Binding(
                get: { photosSourcePendingFullRepair != nil },
                set: { if !$0 { photosSourcePendingFullRepair = nil } }
            ),
            titleVisibility: .visible,
            presenting: photosSourcePendingFullRepair
        ) { source in
            Button("开始完整修复扫描") {
                photosSourcePendingFullRepair = nil
                selection = .source(source.id)
                Task {
                    await model.selectSource(source.id)
                    await model.requestPhotosFullRepair(sourceID: source.id)
                }
            }
            .persistentHelp("重新扫描整个 Apple Photos 图库，并在后台修复错误的缺失状态。")
            Button("取消", role: .cancel) {
                photosSourcePendingFullRepair = nil
            }
            .persistentHelp("关闭确认窗口，不启动完整修复扫描。")
        } message: { _ in
            Text("这会重新扫描整个 Apple Photos 图库，并在后台修复先前可能误标为缺失的照片。扫描期间仍可浏览已有索引；大图库可能需要数分钟。")
        }
    }

    @ViewBuilder
    private var workspaceInspector: some View {
        if selection == .trainingWorkspace {
            TrainingWorkspaceInspectorView(model: model)
        } else if selection == .librarySlimming {
            LibrarySlimmingInspectorView(model: model)
        } else {
            inspector
        }
    }

    @ViewBuilder
    private var keyboardEnabledContent: some View {
        if selection == .trainingWorkspace {
            content
                .navigationTitle("训练工程")
        } else if selection == .librarySlimming {
            content
                .navigationTitle("图库瘦身")
        } else {
            libraryKeyboardEnabledContent
        }
    }

    private var libraryKeyboardEnabledContent: some View {
        content
            .navigationTitle(model.browsingTitle)
            .focusable()
            .focused($contentFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard model.primarySelectedAssetID != nil else { return .ignored }
                model.toggleSinglePhotoView()
                return .handled
            }
            .onKeyPress(.escape) {
                guard model.isSinglePhotoPresented else { return .ignored }
                model.closeSinglePhotoView()
                return .handled
            }
            .onKeyPress("p") { handleReviewDecisionKey(.accept) }
            .onKeyPress("x") { handleReviewDecisionKey(.reject) }
            .onKeyPress("u") { handleSinglePhotoReviewDeferKey() }
            .onKeyPress(keys: [.init("a")], action: handleSelectAllKeyPress)
            .onKeyPress(
                keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                action: handleGridNavigationKey
            )
    }

    private var previewCachePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用存储与预览缓存")
                .font(.headline)
            Text("预览缓存")
                .font(.subheadline)
            LabeledContent("条目", value: "\(model.previewCacheUsage.entryCount)")
            LabeledContent(
                "已登记用量",
                value: formattedByteCount(model.previewCacheUsage.registeredBytes)
            )
            Divider()
            Text("长期 Photos 原图")
                .font(.subheadline)
            LabeledContent(
                "原图副本",
                value: "\(model.photosOriginalStorageUsage.entryCount)"
            )
            LabeledContent(
                "登记用量",
                value: formattedByteCount(
                    UInt64(max(0, model.photosOriginalStorageUsage.registeredBytes))
                )
            )
            Text("保留策略：默认长期保留，不自动过期或按容量淘汰；仅由你在这里手动清理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let location = model.appStorageLocation {
                LabeledContent(
                    "存储位置",
                    value: location.usesExternalStorage ? "外置磁盘" : "内置磁盘"
                )
                if location.requiresRestart {
                    Text("状态：待重启迁移")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("已保存外置根位置。重新启动 ImageAll 后会显示迁移任务与进度，并在目录库打开前完成整包迁移。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if location.usesExternalStorage {
                    Text("状态：外置存储已生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("状态：使用内置 Application Support / Caches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("应用资料")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(location.applicationSupportDirectoryURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("全部缓存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(location.cachesDirectoryURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if location.requiresRestart,
                   let root = location.preferredExternalRootURL
                {
                    Text("重启后应用资料")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        UserDefaultsAppStorageLocationStore
                            .applicationSupportDirectory(under: root).path
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text("重启后全部缓存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        UserDefaultsAppStorageLocationStore
                            .cacheDirectory(under: root).path
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            Button {
                Task { await model.chooseExternalAppStorageLocation() }
            } label: {
                Label("选择外置应用存储位置…", systemImage: "externaldrive.badge.plus")
            }
            .disabled(
                model.isChoosingAppStorageLocation
                    || model.isClearingPreviewCache
                    || model.isClearingPhotosOriginalStorage
            )
            .persistentHelp("选择外置磁盘上的应用数据根目录；保存后需要重启才能迁移并生效。")
            Divider()
            Button("清理预览缓存", role: .destructive) {
                showPreviewCacheClearConfirmation = true
            }
            .disabled(
                model.previewCacheUsage.entryCount == 0 || model.isClearingPreviewCache
            )
            .persistentHelp("打开清理确认；只删除可重建的缩略图和单图预览缓存。")
            Button("清理全部长期原图副本", role: .destructive) {
                showPhotosOriginalStorageClearConfirmation = true
            }
            .disabled(!model.canClearPhotosOriginalStorage)
            .persistentHelp("打开清理确认；删除 ImageAll 自有的 Photos 原图副本，不修改 Apple Photos。")
            if model.isAnalyzingLibrarySlimming,
               model.photosOriginalStorageUsage.entryCount > 0
            {
                Text("相同检测运行期间不能清理；暂停或完成后可操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 380)
        .confirmationDialog(
            "清理预览缓存？",
            isPresented: $showPreviewCacheClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理预览缓存", role: .destructive) {
                showPreviewCachePanel = false
                Task { await model.clearPreviewCache() }
            }
            .persistentHelp("确认删除可重建的预览缓存；原照片、标签和模型不会被删除。")
            Button("取消", role: .cancel) {}
                .persistentHelp("关闭确认窗口并保留预览缓存。")
        } message: {
            Text("只会删除可重建的网格缩略图和单图预览；不会删除原照片、人工标签、Feature Print 或个性化模型。iCloud 预览之后需要再次手动获取。")
        }
        .confirmationDialog(
            "清理全部长期原图副本？",
            isPresented: $showPhotosOriginalStorageClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理全部长期原图副本", role: .destructive) {
                Task { await model.clearPhotosOriginalStorage() }
            }
            .persistentHelp("确认删除 ImageAll 长期保存的 Photos 原图副本；Apple Photos 不会被修改。")
            Button("取消", role: .cancel) {}
                .persistentHelp("关闭确认窗口并保留长期原图副本。")
        } message: {
            Text("只删除 ImageAll 在 Application Support 中长期保存的 Photos 原图副本及其缓存索引。不会修改 Apple Photos、人工标签或已计算的相同检测结果；以后再次需要原图时，“相同”检测可能重新从 iCloud 下载。")
        }
    }

    private var jobActivityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("活动")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshJobActivity() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .persistentHelp("重新读取后台任务的最新进度和可用操作。")
            }

            if model.jobActivityItems.isEmpty {
                ContentUnavailableView(
                    "暂无活动",
                    systemImage: "clock",
                    description: Text("同步和个性化任务会显示在这里。")
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.jobActivityItems) { item in
                            jobActivityRow(item)
                            if item.id != model.jobActivityItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func jobActivityRow(_ item: JobActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(jobActivityTitle(item.kind))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(jobActivityStateText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(jobActivityProgressText(item.progress))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !item.availableActions.isEmpty {
                HStack {
                    ForEach(item.availableActions, id: \.self) { action in
                        Button(jobActivityActionTitle(action), role: action == .cancel ? .destructive : nil) {
                            Task { await model.applyJobActivityAction(action, to: item.id) }
                        }
                        .disabled(model.isApplyingJobActivityAction(item.id))
                        .persistentHelp(jobActivityActionHelp(action))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }

    private func jobActivityTitle(_ kind: JobActivityKind) -> String {
        switch kind {
        case .folderReconcile: "文件夹同步"
        case .photosReconcile: "Apple Photos 同步"
        case .personalizationSuggestions: "个性化建议"
        case .standardSuggestions: "标准模型建议"
        case .librarySlimmingAnalysis: "图库瘦身分析"
        case .librarySlimmingSourceIndex: "来源相似索引"
        case .background: "后台任务"
        }
    }

    private func jobActivityStateText(_ item: JobActivityItem) -> String {
        switch (item.state, item.controlRequest) {
        case (.running, .pause): "正在暂停"
        case (.running, .cancel): "正在取消"
        case (.pending, _): "等待中"
        case (.running, _): "运行中"
        case (.paused, _): "已暂停"
        case (.retryableFailed, _): "等待重试"
        case (.completed, _): "已完成"
        case (.terminalFailed, _): "失败"
        case (.cancelled, _): "已取消"
        }
    }

    private func jobActivityProgressText(_ progress: JobProgress) -> String {
        if let total = progress.total {
            return "进度 \(progress.completed) / \(total)"
        }
        return "已处理 \(progress.completed)"
    }

    private func jobActivityActionTitle(_ action: JobActivityAction) -> String {
        switch action {
        case .pause: "暂停"
        case .resume: "继续"
        case .cancel: "取消"
        }
    }

    private func jobActivityActionHelp(_ action: JobActivityAction) -> String {
        switch action {
        case .pause:
            "暂停这个后台任务，并保存已完成的进度。"
        case .resume:
            "从保存的进度继续这个后台任务。"
        case .cancel:
            "取消这个后台任务；已经安全完成的结果会保留。"
        }
    }

    private func formattedByteCount(_ bytes: UInt64) -> String {
        guard let signedBytes = Int64(exactly: bytes) else { return "超过可显示范围" }
        return ByteCountFormatter.string(fromByteCount: signedBytes, countStyle: .file)
    }

    var body: some View {
        ZStack {
            workspaceWithSourceControls
                .disabled(model.isRunningLibrarySlimmingIdenticalCleanup)

            if let progress = model.librarySlimmingIdenticalCleanupExecutionProgress {
                LibrarySlimmingIdenticalCleanupBlockingOverlay(progress: progress)
                    .zIndex(100)
            }
        }
        .alert(
            "重命名标签",
            isPresented: Binding(
                get: { tagPendingRename != nil },
                set: {
                    if !$0 {
                        tagPendingRename = nil
                        renamedTagName = ""
                    }
                }
            ),
            presenting: tagPendingRename
        ) { tag in
            TextField("标签名称", text: $renamedTagName)
            Button("重命名") {
                let candidate = renamedTagName
                tagPendingRename = nil
                renamedTagName = ""
                Task { _ = await model.renameTag(tag.id, to: candidate) }
            }
            .disabled(TagNameNormalizer.trimUnicodeWhiteSpace(renamedTagName).isEmpty)
            .persistentHelp("保存新的标签名称；已有人工确认、拒绝和历史都会保留。")
            Button("取消", role: .cancel) {
                tagPendingRename = nil
                renamedTagName = ""
            }
            .persistentHelp("放弃名称修改并关闭窗口。")
        } message: { tag in
            Text("为“\(tag.displayName)”输入新名称。现有人工标签决定会保留。")
        }
        .alert(
            "新建分组",
            isPresented: $showCreateTagGroupAlert
        ) {
            TextField("分组名称", text: $newTagGroupName)
            Button("创建") {
                let candidate = newTagGroupName
                newTagGroupName = ""
                showCreateTagGroupAlert = false
                Task { _ = await model.createTagGroup(named: candidate) }
            }
            .disabled(TagNameNormalizer.trimUnicodeWhiteSpace(newTagGroupName).isEmpty)
            .persistentHelp("使用输入的名称创建一个可折叠标签分组。")
            Button("取消", role: .cancel) {
                newTagGroupName = ""
                showCreateTagGroupAlert = false
            }
            .persistentHelp("放弃新建分组并关闭窗口。")
        } message: {
            Text("创建一个可折叠的标签分组，之后可把标签拖入该组。")
        }
        .alert(
            "重命名分组",
            isPresented: Binding(
                get: { tagGroupPendingRename != nil },
                set: {
                    if !$0 {
                        tagGroupPendingRename = nil
                        renamedTagGroupName = ""
                    }
                }
            ),
            presenting: tagGroupPendingRename
        ) { group in
            TextField("分组名称", text: $renamedTagGroupName)
            Button("重命名") {
                let candidate = renamedTagGroupName
                let groupID = group.id
                tagGroupPendingRename = nil
                renamedTagGroupName = ""
                Task { _ = await model.renameTagGroup(groupID, to: candidate) }
            }
            .disabled(TagNameNormalizer.trimUnicodeWhiteSpace(renamedTagGroupName).isEmpty)
            .persistentHelp("保存新的分组名称；组内标签不会改变。")
            Button("取消", role: .cancel) {
                tagGroupPendingRename = nil
                renamedTagGroupName = ""
            }
            .persistentHelp("放弃分组名称修改并关闭窗口。")
        } message: { group in
            Text("为“\(group.displayName)”输入新名称。")
        }
        .confirmationDialog(
            tagGroupPendingDelete.map { "删除“\($0.displayName)”分组？" } ?? "删除分组？",
            isPresented: Binding(
                get: { tagGroupPendingDelete != nil },
                set: { if !$0 { tagGroupPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: tagGroupPendingDelete
        ) { group in
            Button("删除分组", role: .destructive) {
                let groupID = group.id
                tagGroupPendingDelete = nil
                Task { _ = await model.deleteTagGroup(groupID) }
            }
            .persistentHelp("删除这个自定义分组，并把其中标签移到“其他”；不会删除标签决定。")
            Button("取消", role: .cancel) {
                tagGroupPendingDelete = nil
            }
            .persistentHelp("关闭确认窗口并保留分组。")
        } message: { _ in
            Text("组内标签会移到「\(TagGroupSeed.other.displayName)」。系统默认分组不可删除。")
        }
        .confirmationDialog(
            tagPendingArchive.map { "归档“\($0.displayName)”标签？" } ?? "归档标签？",
            isPresented: Binding(
                get: { tagPendingArchive != nil },
                set: { if !$0 { tagPendingArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: tagPendingArchive
        ) { tag in
            Button("归档标签", role: .destructive) {
                let hadTagFilters = model.isTagFilterIncluded(tag.id) || model.isTagFilterExcluded(tag.id)
                tagPendingArchive = nil
                Task {
                    if await model.archiveTag(tag.id), hadTagFilters {
                        await model.clearTagFilters()
                    }
                }
            }
            .persistentHelp("从界面隐藏这个标签，但保留已经保存的人工决定和历史。")
            Button("取消", role: .cancel) {
                tagPendingArchive = nil
            }
            .persistentHelp("关闭确认窗口并保留标签可见。")
        } message: { _ in
            Text("标签会从侧栏和编辑器隐藏，但已保存的人工确认、拒绝和历史都会保留。")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .commandPalette:
                commandPalette
            case .keyboardShortcuts:
                keyboardShortcuts
            }
        }
        .task { await model.start() }
        .onChange(of: searchText) { _, _ in
            model.noteUserInteractionForIdlePrewarm()
        }
        .onChange(of: selection) { _, newValue in
            model.noteUserInteractionForIdlePrewarm()
            let destination: LibraryBrowsingDestination = switch newValue {
            case .all, .none:
                .all
            case .untagged:
                .untagged
            case .reviewSuggestions:
                .reviewSuggestions
            case .trainingWorkspace:
                .trainingWorkspace
            case .librarySlimming:
                .librarySlimming
            case let .source(sourceID):
                .source(sourceID)
            }
            model.applyImmediateBrowsingPresentation(for: destination)
            let requestID = model.beginBrowsingNavigation()
            if destination == .librarySlimming {
                model.bindPendingLibrarySlimmingSeedAnalyzeIfNeeded(to: requestID)
            } else {
                model.cancelPendingLibrarySlimmingSeedAnalyze()
            }
            Task {
                await model.navigate(to: destination, requestID: requestID)
            }
        }
        .onChange(of: model.librarySlimmingNavigationNonce) { _, _ in
            if selection != .librarySlimming {
                selection = .librarySlimming
            } else {
                Task { await model.consumePendingLibrarySlimmingSeedAnalyzeIfNeeded() }
            }
        }
    }

    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layoutState.isSidebarPresented ? .all : .detailOnly },
            set: { layoutState.setSidebarPresented($0 != .detailOnly) }
        )
    }

    private var inspectorVisibility: Binding<Bool> {
        Binding(
            get: { layoutState.isInspectorPresented },
            set: { layoutState.setInspectorPresented($0) }
        )
    }

    private var commandPalette: some View {
        let commands = model.workspaceCommands(matching: commandSearchText, layout: layoutState)
        return VStack(alignment: .leading, spacing: 12) {
            Text("命令")
                .font(.headline)
            TextField("搜索命令", text: $commandSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($commandSearchFieldFocused)
                .onSubmit {
                    if let command = commands.first(where: \.isEnabled) {
                        execute(command.command)
                    }
                }

            if commands.isEmpty {
                ContentUnavailableView.search(text: commandSearchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(commands) { item in
                    Button {
                        execute(item.command)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                    .persistentHelp("执行“\(item.title)”命令。")
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .frame(width: 460, height: 500)
        .accessibilityIdentifier("libraryCommandPalette")
        .onAppear {
            commandSearchText = ""
            commandSearchFieldFocused = true
        }
        .onExitCommand {
            activeSheet = nil
        }
    }

    private var keyboardShortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("快捷键")
                    .font(.title2.bold())
                Spacer()
                Button("完成") {
                    activeSheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .persistentHelp("关闭快捷键说明窗口。")
            }
            shortcutRow("打开命令面板", keys: "⌘K")
            shortcutRow("全选当前照片", keys: "⌘A")
            shortcutRow("切换单图查看", keys: "Space")
            shortcutRow("返回照片网格", keys: "Esc")
            shortcutRow("移动照片选择", keys: "←  ↑  ↓  →")
            shortcutRow("按当前网格页幅翻页", keys: "Page Up / Page Down")
            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 300)
        .onExitCommand {
            activeSheet = nil
        }
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func execute(_ command: LibraryWorkspaceCommand) {
        if command == .showKeyboardShortcuts {
            activeSheet = .keyboardShortcuts
            return
        }

        activeSheet = nil
        switch command {
        case .showAllPhotos:
            selection = .all
        case .showReviewSuggestions:
            selection = .reviewSuggestions
        case .showActivity:
            Task { @MainActor in
                await Task.yield()
                showJobActivityPanel = true
                await model.refreshJobActivity()
            }
        case .toggleSidebar:
            layoutState.toggleSidebar()
        case .toggleInspector:
            layoutState.toggleInspector()
        case let .showSource(sourceID):
            selection = .source(sourceID)
        case let .showTag(tagID):
            Task { await model.filterToSingleIncludedTag(tagID) }
        case let .acceptTag(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .accept) }
        case let .rejectTag(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .reject) }
        case let .clearTagDecision(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .clear) }
        case .createTag:
            newTagFieldFocused = true
        case .connectFolder:
            Task { await model.connectFolder() }
        case .rescanCurrentSource:
            Task { await model.rescan() }
        case .toggleSinglePhoto:
            model.toggleSinglePhotoView()
        case .showKeyboardShortcuts:
            break
        }
    }

    private func handleSelectAllKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers.contains(.command) else { return .ignored }
        return handleSelectAllKey()
    }

    private func handleSelectAllKey() -> KeyPress.Result {
        guard contentFocused, !model.isSinglePhotoPresented else { return .ignored }
        let hasVisibleItems = model.reviewMode == nil
            ? !model.items.isEmpty
            : !model.reviewQueueItems.isEmpty
        guard hasVisibleItems else { return .ignored }
        Task { await model.selectAllVisibleAssets() }
        return .handled
    }

    private func handleGridNavigationKey(_ keyPress: KeyPress) -> KeyPress.Result {
        let hasNavigableItems = model.reviewMode == nil
            ? !model.items.isEmpty
            : !model.reviewQueueItems.isEmpty
        guard hasNavigableItems else { return .ignored }
        let direction: LibraryGridNavigationDirection
        switch keyPress.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }

        if model.isSinglePhotoPresented, direction == .up || direction == .down {
            return .ignored
        }
        if model.reviewMode != nil {
            guard direction == .left || direction == .right else { return .ignored }
            Task {
                await model.moveReviewPrimarySelection(in: direction, columnCount: 1)
            }
            return .handled
        }

        Task {
            await model.movePrimarySelection(in: direction, columnCount: gridColumnCount)
            gridScrollTargetID = model.primarySelectedAssetID
        }
        return .handled
    }

    private var gridPageKeyHandlingEnabled: Bool {
        !model.isSinglePhotoPresented
            && model.reviewMode == nil
            && !model.items.isEmpty
    }

    private func handleGridPageNavigation(_ direction: LibraryGridPageDirection) {
        guard gridPageKeyHandlingEnabled else { return }
        contentFocused = true
        Task {
            await model.movePrimarySelection(
                byPage: direction,
                pageItemCount: gridPageItemCount
            )
            gridScrollTargetID = model.primarySelectedAssetID
        }
    }

    private func handleReviewDecisionKey(
        _ action: LibraryTagDecisionAction
    ) -> KeyPress.Result {
        guard contentFocused,
              model.reviewMode != nil,
              !model.selectedAssetIDs.isEmpty
        else { return .ignored }
        Task { await model.applyReviewDecision(action: action) }
        return .handled
    }

    private func handleSinglePhotoReviewDeferKey() -> KeyPress.Result {
        guard contentFocused,
              model.isSinglePhotoPresented,
              model.reviewMode != nil,
              !model.selectedAssetIDs.isEmpty
        else { return .ignored }
        Task { await model.deferReviewSelection() }
        return .handled
    }

    private var sidebar: some View {
        let orderedSources = model.orderedSources
        return List(selection: $selection) {
            Section("图库") {
                Label("全部照片", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySidebarSelection.all)
                Label("无标签", systemImage: "tag.slash")
                    .tag(LibrarySidebarSelection.untagged)
                HStack {
                    Label("待审核建议", systemImage: "sparkles")
                    Spacer()
                    if model.pendingSuggestionTotal > 0 {
                        Text("\(model.pendingSuggestionTotal)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(LibrarySidebarSelection.reviewSuggestions)
                Label("训练工程", systemImage: "hammer")
                    .tag(LibrarySidebarSelection.trainingWorkspace)
                Label("图库瘦身", systemImage: "square.stack.3d.up")
                    .tag(LibrarySidebarSelection.librarySlimming)
            }
            Section("来源") {
                ForEach(orderedSources) { source in
                    sourceRow(source)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: Self.sourceDropRowHeight,
                            maxHeight: Self.sourceDropRowHeight,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: LibrarySourceRowFramePreferenceKey.self,
                                    value: [
                                        source.id: proxy.frame(
                                            in: .named(Self.sourceReorderCoordinateSpace)
                                        ),
                                    ]
                                )
                            }
                        }
                        .overlay {
                            sourceInsertionIndicator(
                                for: source.id,
                                orderedSources: orderedSources
                            )
                        }
                        .opacity(draggedSourceID == source.id ? 0.55 : 1)
                        .tag(LibrarySidebarSelection.source(source.id))
                        .onTapGesture {
                            selection = .source(source.id)
                        }
                        .simultaneousGesture(sourceReorderGesture(for: source.id))
                }
                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .persistentHelp("选择一个本地文件夹作为照片来源；ImageAll 只索引，不修改原文件。")
                if model.sources.contains(where: { $0.kind == .photos && $0.state == .active }) {
                    Label("已连接 Apple Photos", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if !model.sources.contains(where: { $0.kind == .photos }) {
                    Button {
                        showPhotosConnectionExplanation = true
                    } label: {
                        Label("连接 Apple Photos…", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .persistentHelp("请求照片访问权限，并连接当前系统 Apple Photos 图库。")
                }
            }
            Section("标签") {
                ForEach(model.tagGroupSections) { section in
                    let isCollapsed = model.isTagGroupCollapsed(section.group.id)
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            model.toggleTagGroupCollapsed(section.group.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                Text(section.group.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                                if !section.tags.isEmpty {
                                    Text("\(section.tags.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .persistentHelp(
                            isCollapsed
                                ? "展开“\(section.group.displayName)”分组，显示其中标签。"
                                : "折叠“\(section.group.displayName)”分组，暂时隐藏其中标签。"
                        )
                        .contextMenu {
                            if !section.group.isSystem {
                                Button("重命名分组…") {
                                    renamedTagGroupName = section.group.displayName
                                    tagGroupPendingRename = section.group
                                }
                                .persistentHelp("打开重命名窗口，修改这个分组的显示名称。")
                                Button("删除分组", role: .destructive) {
                                    tagGroupPendingDelete = section.group
                                }
                                .persistentHelp("打开删除确认；组内标签会移到“其他”。")
                            }
                        }

                        if !isCollapsed {
                            LibraryTagFlowLayout {
                                ForEach(section.tags, id: \.id) { tag in
                                    tagRow(tag)
                                        .background {
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: LibraryTagChipFramePreferenceKey.self,
                                                    value: [
                                                        tag.id: proxy.frame(
                                                            in: .named(Self.sourceReorderCoordinateSpace)
                                                        ),
                                                    ]
                                                )
                                            }
                                        }
                                        .overlay {
                                            tagInsertionIndicator(for: tag.id, in: section)
                                        }
                                        .opacity(draggedTagID == tag.id ? 0.55 : 1)
                                        .simultaneousGesture(
                                            tagReorderGesture(
                                                tagID: tag.id,
                                                groupID: section.group.id,
                                                tagIDs: section.tags.map(\.id)
                                            )
                                        )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(4)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: LibraryTagGroupContainerFramePreferenceKey.self,
                                    value: [
                                        section.group.id: proxy.frame(
                                            in: .named(Self.sourceReorderCoordinateSpace)
                                        ),
                                    ]
                                )
                                .overlay {
                                    if tagDropTargetGroupID == section.group.id {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(0.12))
                                    }
                                }
                        }
                    }
                }
                Button {
                    newTagGroupName = ""
                    showCreateTagGroupAlert = true
                } label: {
                    Label("新建分组…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .persistentHelp("创建一个新的可折叠标签分组。")
                Button {
                    Task { await model.installPresetTags() }
                } label: {
                    Label("添加常用标签", systemImage: "tag.badge.plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .persistentHelp("安装一组可编辑的常用标签；不会分析照片或自动应用标签。")
                Button {
                    newTagFieldFocused = true
                } label: {
                    Label("新建标签…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.selectedAssetIDs.isEmpty)
                .persistentHelp("把光标移到新标签输入框，为当前所选照片创建并确认标签。")
            }
        }
        .coordinateSpace(name: Self.sourceReorderCoordinateSpace)
        .coordinateSpace(name: Self.sourceReorderCoordinateSpace)
        .onPreferenceChange(LibrarySourceRowFramePreferenceKey.self) { frames in
            sourceRowFrames = frames
        }
        .onPreferenceChange(LibraryTagChipFramePreferenceKey.self) { frames in
            tagChipFrames = frames
        }
        .onPreferenceChange(LibraryTagGroupContainerFramePreferenceKey.self) { frames in
            tagGroupContainerFrames = frames
        }
        .listStyle(.sidebar)
        .navigationTitle("ImageAll")
    }

    private func sourceReorderGesture(for sourceID: UUID) -> some Gesture {
        DragGesture(
            minimumDistance: 12,
            coordinateSpace: .local
        )
        .onChanged { value in
            let orderedSources = model.orderedSources
            let visibleFrames = sourceRowFrames.values.sorted { $0.minY < $1.minY }
            guard visibleFrames.count == orderedSources.count else { return }
            guard let sourceOffset = orderedSources.firstIndex(where: { $0.id == sourceID })
            else { return }
            draggedSourceID = sourceID
            sourceInsertionOffset = LibrarySourceReorderLayout.destinationOffset(
                pointerY: visibleFrames[sourceOffset].minY + value.location.y,
                rowFrames: visibleFrames
            )
        }
        .onEnded { value in
            defer {
                draggedSourceID = nil
                sourceInsertionOffset = nil
            }
            let orderedSources = model.orderedSources
            guard let move = LibrarySourceReorderLayout.moveRequest(
                sourceID: sourceID,
                localPointerY: value.location.y,
                sourceIDs: orderedSources.map(\.id),
                rowFrames: Array(sourceRowFrames.values)
            ) else { return }
            model.moveSources(
                fromOffsets: IndexSet(integer: move.sourceOffset),
                toOffset: move.destinationOffset
            )
        }
    }

    private func tagReorderGesture(
        tagID: UUID,
        groupID: UUID,
        tagIDs: [UUID]
    ) -> some Gesture {
        DragGesture(
            minimumDistance: 12,
            coordinateSpace: .local
        )
        .onChanged { value in
            guard let pointer = tagReorderPointer(tagID: tagID, location: value.location) else {
                return
            }
            draggedTagID = tagID
            draggedTagGroupID = groupID
            if let targetGroupID = LibraryTagReorderLayout.targetGroupID(
                pointer: pointer,
                groupFrames: tagGroupContainerFrames
            ) {
                tagDropTargetGroupID = targetGroupID
                if targetGroupID != groupID {
                    tagInsertionGroupID = nil
                    tagInsertionOffset = nil
                    return
                }
            }
            let visibleTagIDs = tagIDs.filter { tagChipFrames[$0] != nil }
            guard visibleTagIDs.count == tagIDs.count else { return }
            tagInsertionGroupID = groupID
            tagInsertionOffset = LibraryTagReorderLayout.destinationOffset(
                pointer: pointer,
                tagIDs: tagIDs,
                frames: tagChipFrames
            )
        }
        .onEnded { value in
            defer {
                draggedTagID = nil
                draggedTagGroupID = nil
                tagInsertionOffset = nil
                tagInsertionGroupID = nil
                tagDropTargetGroupID = nil
            }
            guard let pointer = tagReorderPointer(tagID: tagID, location: value.location) else {
                return
            }
            if let targetGroupID = LibraryTagReorderLayout.targetGroupID(
                pointer: pointer,
                groupFrames: tagGroupContainerFrames
            ), targetGroupID != groupID {
                _ = model.acceptAndEnqueueMoveTag(tagID, toGroupID: targetGroupID)
                return
            }
            guard let move = LibraryTagReorderLayout.moveRequest(
                tagID: tagID,
                pointer: pointer,
                tagIDs: tagIDs,
                frames: tagChipFrames
            ) else { return }
            model.moveTags(
                in: groupID,
                fromOffsets: IndexSet(integer: move.sourceOffset),
                toOffset: move.destinationOffset
            )
        }
    }

    private func tagReorderPointer(tagID: UUID, location: CGPoint) -> CGPoint? {
        guard let sourceFrame = tagChipFrames[tagID] else { return nil }
        return CGPoint(
            x: sourceFrame.minX + location.x,
            y: sourceFrame.minY + location.y
        )
    }

    @ViewBuilder
    private func tagInsertionIndicator(
        for tagID: UUID,
        in section: LibraryTagGroupSection
    ) -> some View {
        if draggedTagGroupID == section.group.id,
           tagInsertionGroupID == section.group.id,
           let insertionOffset = tagInsertionOffset,
           let tagIndex = section.tags.firstIndex(where: { $0.id == tagID })
        {
            if insertionOffset == tagIndex {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            } else if tagIndex == section.tags.count - 1,
                      insertionOffset == section.tags.count
            {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func sourceInsertionIndicator(
        for sourceID: UUID,
        orderedSources: [LibrarySourceSummary]
    ) -> some View {
        if let sourceIndex = orderedSources.firstIndex(where: { $0.id == sourceID }) {
            if sourceInsertionOffset == sourceIndex {
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            } else if sourceIndex == orderedSources.count - 1,
                      sourceInsertionOffset == orderedSources.count
            {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func tagRow(_ tag: TagListItem) -> some View {
        let isIncluded = model.isTagFilterIncluded(tag.id)
        let isExcluded = model.isTagFilterExcluded(tag.id)
        let usesIntersection = isIncluded && model.tagMatchMode == .all

        return HStack(spacing: 5) {
            Label {
                Text(tag.displayName)
                    .lineLimit(1)
            } icon: {
                Image(systemName: isExcluded ? "tag.slash" : "tag")
            }
            if isIncluded {
                if usesIntersection {
                    Text("∩")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else if isExcluded {
                Image(systemName: "minus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(maxWidth: 180, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .background {
            if isIncluded {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        usesIntersection
                            ? Color.orange.opacity(0.18)
                            : Color.accentColor.opacity(0.18)
                    )
            } else if isExcluded {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.12))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
            }
        }
        .foregroundStyle(isExcluded ? Color.red : Color.primary)
        .onTapGesture {
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task {
                if flags.contains(.command), flags.contains(.option) {
                    await model.toggleExcludedTagFilter(tag.id)
                } else if flags.contains(.command) {
                    await model.toggleIncludedTagFilter(tag.id, matchMode: .all)
                } else {
                    await model.toggleIncludedTagFilter(tag.id, matchMode: .any)
                }
            }
        }
        .persistentHelp(
            isExcluded
                ? "⌘⌥点击取消排除；拖拽可调整顺序"
                : isIncluded
                    ? (usesIntersection
                        ? "交集筛选；⌘点击切换；⌘⌥点击排除；拖拽可调整顺序"
                        : "并集筛选；⌘点击改为交集；⌘⌥点击排除；拖拽可调整顺序")
                    : "点击并集筛选；⌘点击交集筛选；⌘⌥点击排除；拖拽可调整顺序"
        )
        .contextMenu {
            Button("仅筛选此标签") {
                Task { await model.filterToSingleIncludedTag(tag.id) }
            }
            .persistentHelp("清除其他标签条件，只显示符合“\(tag.displayName)”的照片。")
            Button("排除此标签") {
                Task { await model.toggleExcludedTagFilter(tag.id) }
            }
            .persistentHelp("在当前筛选中排除带有“\(tag.displayName)”的照片。")
            Button("重命名…") {
                renamedTagName = tag.displayName
                tagPendingRename = tag
            }
            .persistentHelp("打开重命名窗口，修改这个标签的显示名称。")

            Divider()

            Button("归档标签", role: .destructive) {
                tagPendingArchive = tag
            }
            .persistentHelp("打开归档确认；标签会隐藏，但人工决定和历史会保留。")
        }
    }

    private func sourceRow(_ source: LibrarySourceSummary) -> some View {
        HStack(spacing: 8) {
            Label(
                source.displayName,
                systemImage: source.kind == .photos ? "photo.on.rectangle" : sourceIcon(source.state)
            )
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = source.kind == .photos && source.state == .unavailable
                ? "历史"
                : sourceStatusText(source.state)
            {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .persistentHelp(sourceHelpText(source.state) + "；拖拽可调整来源顺序")
        .contextMenu {
            Button("在图库中查看") {
                selection = .source(source.id)
            }
            .persistentHelp("切换图库，只显示“\(source.displayName)”来源中的照片。")
            Button(source.kind == .photos ? "立即同步" : "立即重扫") {
                selection = .source(source.id)
                Task {
                    await model.selectSource(source.id)
                    if source.kind == .photos {
                        await model.syncPhotosLibrary(sourceID: source.id)
                    } else {
                        await model.rescan()
                    }
                }
            }
            .disabled(model.isBusy || source.state != .active)
            .persistentHelp(
                source.kind == .photos
                    ? "同步“\(source.displayName)”的最新 Apple Photos 变化。"
                    : "重新扫描“\(source.displayName)”并更新照片索引。"
            )

            Button("预热缩略图缓存") {
                model.prewarmSourceThumbnails(sourceID: source.id)
            }
            .disabled(
                model.isPrewarmingSourceThumbnails
                    || source.state == .disabled
                    || source.state == .authorizationRequired
            )
            .persistentHelp("在后台预先生成这个来源的网格缩略图，让后续浏览更快。")

            if source.kind == .photos && source.state == .active {
                Button("完整修复扫描…") {
                    photosSourcePendingFullRepair = source
                }
                .disabled(model.isBusy)
                .persistentHelp("打开确认窗口，重新扫描整个 Apple Photos 图库并修复缺失状态。")
            }

            if source.kind == .photos && source.state == .unavailable {
                Button("连接当前系统图库…") {
                    photosSourcePendingRebind = source
                }
                .disabled(model.isBusy)
                .persistentHelp("保留旧图库历史，并把当前系统照片图库连接为新来源。")
            } else {
                Button(source.kind == .photos && source.state == .disabled ? "重新启用…" : "重新授权…") {
                    Task { await model.reauthorizeSource(source.id) }
                }
                .disabled(
                    model.isBusy ||
                    (source.kind == .folder && source.state != .unavailable && source.state != .authorizationRequired) ||
                    (source.kind == .photos && source.state != .authorizationRequired && source.state != .disabled)
                )
                .persistentHelp(
                    source.kind == .photos
                        ? "重新请求 Apple Photos 权限或重新启用这个来源。"
                        : "重新选择文件夹，恢复这个来源的访问授权。"
                )
            }

            if source.kind == .folder && source.state == .active {
                Button("更新回收权限…") {
                    Task { await model.refreshFolderMutationAuthorization(source.id) }
                }
                .disabled(model.isBusy)
                .persistentHelp(
                    "仅在删除或恢复提示已有来源权限不可用时使用；由您明确选择原文件夹更新权限。"
                )
            }

            Divider()

            Button("停用来源", role: .destructive) {
                sourcePendingDisable = source
            }
            .disabled(
                model.isBusy || source.state == .disabled ||
                (source.kind == .photos && source.state == .unavailable)
            )
            .persistentHelp("停止扫描这个来源，但保留索引、人工标签和历史；不会修改原照片。")
        }
    }

    @ViewBuilder
    private var content: some View {
        if selection == .trainingWorkspace {
            TrainingWorkspaceView(
                model: model,
                onReturnToLibrary: {
                    selection = .all
                }
            )
        } else if selection == .librarySlimming {
            LibrarySlimmingWorkspaceView(
                model: model,
                onReturnToLibrary: {
                    selection = .all
                }
            )
        } else {
            libraryContent
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            mediaKindTabs
            Divider()
            libraryContentBody
        }
    }

    private var mediaKindTabs: some View {
        MediaKindWorkspaceTabs(
            selection: model.selectedMediaKind,
            accessibilityIdentifier: "libraryMediaKindTabs",
            help: "在当前入口内切换照片和视频；两个页面的数据和选择严格隔离。"
        ) { mediaKind in
            Task { await model.setMediaKind(mediaKind) }
        }
    }

    @ViewBuilder
    private var libraryContentBody: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在打开图库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ProgressView("正在扫描照片…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            if model.showsFirstUseGuide {
                ContentUnavailableView {
                    Label("开始建立你的照片资料库", systemImage: "photo.stack")
                } description: {
                    Text("连接一个照片来源，也可以添加一组可编辑的常用标签。常用标签不会分析照片，也不会自动应用到任何照片。")
                } actions: {
                    Button("连接照片文件夹…") {
                        Task { await model.connectFolder() }
                    }
                    .buttonStyle(.borderedProminent)
                    .persistentHelp("选择本地文件夹作为照片来源；ImageAll 只索引，不修改原文件。")
                    Button("连接 Apple Photos…") {
                        showPhotosConnectionExplanation = true
                    }
                    .buttonStyle(.bordered)
                    .persistentHelp("请求照片访问权限，并连接当前系统 Apple Photos 图库。")
                    Button("添加常用标签") {
                        Task { await model.installPresetTags() }
                    }
                    .buttonStyle(.bordered)
                    .persistentHelp("安装一组可编辑的常用标签；不会分析照片或自动应用标签。")
                }
            } else {
                ContentUnavailableView {
                    Label("ImageAll 在原位置读取照片", systemImage: "photo.stack")
                } description: {
                    Text("不会导入、移动、重命名或删除原图。索引、标签和缩略图保存在 ImageAll 自己的应用容器中。")
                } actions: {
                    Button("连接照片文件夹…") {
                        Task { await model.connectFolder() }
                    }
                    .buttonStyle(.borderedProminent)
                    .persistentHelp("选择本地文件夹作为照片来源；ImageAll 只索引，不修改原文件。")
                    Button("连接 Apple Photos…") {
                        showPhotosConnectionExplanation = true
                    }
                    .buttonStyle(.bordered)
                    .persistentHelp("请求照片访问权限，并连接当前系统 Apple Photos 图库。")
                }
            }
        case .content:
            if case .overview = model.reviewMode {
                ReviewOverviewView(
                    model: model,
                    onOpenQueue: { tagID, name in
                        Task { await model.enterReviewQueue(tagID: tagID, displayName: name) }
                    },
                    onBack: {
                        selection = .all
                    }
                )
            } else if case let .tagQueue(tagID, displayName) = model.reviewMode {
                if model.isSinglePhotoPresented,
                   let assetID = model.primarySelectedAssetID,
                   let item = model.reviewQueueItems.first(where: {
                       if let selectedReviewItemID = model.selectedReviewItemID {
                           return $0.id == selectedReviewItemID
                       }
                       return $0.assetID == assetID
                   })
                {
                    SinglePhotoReviewView(item: item, model: model)
                        .onAppear { contentFocused = true }
                } else {
                    ReviewQueueContentView(
                        model: model,
                        tagID: tagID,
                        displayName: displayName,
                        contentFocused: $contentFocused
                    )
                }
            } else if model.items.isEmpty {
                if model.hasAssetPropertyFilters {
                    ContentUnavailableView {
                            Label(
                                "没有符合筛选的\(model.selectedMediaKind.displayName)",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                    } description: {
                        Text("请调整可用状态或文件格式筛选。")
                    } actions: {
                        Button("清除状态和格式筛选") {
                            Task { await model.clearAssetPropertyFilters() }
                        }
                        .persistentHelp("清除可用状态和文件格式条件，恢复显示当前范围内的全部照片。")
                    }
                } else {
                    if model.selectedSourceIsPhotos {
                        if let unavailableSource = model.selectedUnavailablePhotosSource {
                            ContentUnavailableView {
                                Label("系统照片图库已更换", systemImage: "photo.badge.exclamationmark")
                            } description: {
                                Text("旧来源的索引、人工标签和历史仍保留。确认后可为当前系统照片图库创建一个新的来源。")
                            } actions: {
                                Button("保留历史并连接当前图库…") {
                                    photosSourcePendingRebind = unavailableSource
                                }
                                .persistentHelp("保留旧图库的索引与标签，并连接当前系统照片图库为新来源。")
                            }
                        } else if model.selectedPhotosSourceNeedsAuthorization || model.notice == .photosAuthorizationRequired {
                            ContentUnavailableView {
                                Label("需要照片访问权限", systemImage: "lock.trianglebadge.exclamationmark")
                            } description: {
                                Text("请允许 ImageAll 访问照片。Debug App 重新构建后，macOS 可能要求再次授权。")
                            }                             actions: {
                                Button("重新检查并同步") {
                                    Task {
                                        if let photosSource = model.sources.first(where: { $0.kind == .photos }) {
                                            await model.reauthorizeSource(photosSource.id)
                                        } else {
                                            await model.connectPhotos()
                                        }
                                    }
                                }
                                .persistentHelp("重新请求或检查照片权限，并同步当前系统照片图库。")
                                Button("打开照片权限设置…") {
                                    openPhotosPrivacySettings()
                                }
                                .persistentHelp("打开 macOS 的照片隐私设置，以便调整 ImageAll 的访问权限。")
                            }
                        } else {
                            ContentUnavailableView {
                                Label("系统照片图库中没有可访问的照片", systemImage: "photo.on.rectangle")
                            } description: {
                                Text("ImageAll 只能读取 Mac 的系统照片图库。如果 Photos 当前打开的是另一个图库，请先在 Photos > 设置 > 通用中确认系统照片图库。更改系统图库可能影响 iCloud Photos。")
                            }                             actions: {
                                Button("立即同步") {
                                    Task {
                                        if let photosSource = model.sources.first(where: {
                                            $0.kind == .photos && $0.state == .active
                                        }) {
                                            await model.syncPhotosLibrary(sourceID: photosSource.id)
                                        } else {
                                            await model.connectPhotos()
                                        }
                                    }
                                }
                                .persistentHelp("立即同步当前系统照片图库，更新照片索引和可用状态。")
                            }
                        }
                    } else {
                        ContentUnavailableView {
                            Label(
                                "没有支持的\(model.selectedMediaKind.displayName)",
                                systemImage: model.selectedMediaKind.systemImage
                            )
                        } description: {
                            if model.selectedMediaKind == .image {
                                Text("支持 JPEG、PNG、HEIC/HEIF、TIFF、WebP、JPEG 2000、静态 GIF 和 RAW（富士/Adobe 等）。")
                            } else {
                                Text("支持系统可读取的 MOV、MP4、M4V 等视频；视频以代表缩略图显示。")
                            }
                        } actions: {
                            Button("立即重扫") {
                                Task { await model.rescan() }
                            }
                            .persistentHelp("重新扫描当前文件夹来源，寻找支持的媒体并更新索引。")
                        }
                    }
                }
            } else {
                if model.isSinglePhotoPresented,
                   let assetID = model.primarySelectedAssetID,
                   let item = model.items.first(where: { $0.assetID == assetID })
                {
                    SinglePhotoView(item: item, model: model)
                        .onAppear { contentFocused = true }
                } else {
                    VStack(spacing: 0) {
                        if model.hasActiveTagFilters, let summary = model.tagFilterSummaryText() {
                            tagFilterSummaryBar(summary)
                        }
                        assetGrid
                    }
                }
            }
        case let .failed(error):
            ContentUnavailableView {
                Label(errorTitle(error), systemImage: "exclamationmark.triangle")
            } description: {
                Text("原照片没有被修改。请检查来源是否仍可用、授权是否有效，然后重试。")
            } actions: {
                Button("重试") {
                    Task { await model.rescan() }
                }
                .disabled(model.sources.isEmpty)
                .persistentHelp("重新访问当前来源并再次扫描；不会修改原照片。")
            }
        }
    }

    private var assetGrid: some View {
        GeometryReader { proxy in
            let layoutWidth = LibraryGridLayout.layoutWidth(containerWidth: proxy.size.width)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LibraryGridMarqueeContainer(
                        cellFrames: gridCellFrames,
                        isMarqueeSelecting: $isMarqueeSelecting,
                        viewportHeight: proxy.size.height,
                        contentWidth: layoutWidth,
                        currentSelection: model.selectedAssetIDs,
                        onSelectionChange: { assetIDs, isFinal in
                            contentFocused = true
                            Task {
                                await model.selectAssets(
                                    assetIDs,
                                    shouldRefreshInspector: isFinal
                                )
                            }
                        }
                    ) {
                        LazyVGrid(
                            columns: LibraryGridLayout.gridItems(
                                containerWidth: proxy.size.width,
                                density: model.gridDensity
                            ),
                            spacing: LibraryGridLayout.spacing
                        ) {
                            ForEach(model.items, id: \.assetID) { item in
                                AssetThumbnailView(
                                    item: item,
                                    model: model,
                                    isSelected: model.selectedAssetIDs.contains(item.assetID),
                                    onSelect: {
                                        guard !isMarqueeSelecting else { return }
                                        contentFocused = true
                                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                        Task {
                                            await model.selectAsset(
                                                item.assetID,
                                                additive: flags.contains(.command),
                                                extendRange: flags.contains(.shift)
                                            )
                                        }
                                    },
                                    onOpen: {
                                        contentFocused = true
                                        Task {
                                            await model.openSinglePhotoView(assetID: item.assetID)
                                        }
                                    }
                                )
                                    .libraryGridCellFrameReporter(assetID: item.assetID)
                                    .id(item.assetID)
                                    .task {
                                        await model.loadMoreIfNeeded(currentAssetID: item.assetID)
                                    }
                            }
                        }
                        .id(model.assetGridRevision)
                        .padding(LibraryGridLayout.horizontalPadding)
                    }
                }
                .scrollDisabled(isMarqueeSelecting)
                .libraryGridPageKeyHandling(
                    isEnabled: gridPageKeyHandlingEnabled,
                    onPageKey: handleGridPageNavigation
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("\(model.selectedMediaKind.displayName)网格")
                .onAppear {
                    updateGridMetrics(containerSize: proxy.size)
                    contentFocused = true
                    gridScrollTargetID = model.primarySelectedAssetID
                }
                .onChange(of: proxy.size) { _, size in
                    updateGridMetrics(containerSize: size)
                }
                .onChange(of: model.gridDensity) { _, _ in
                    updateGridMetrics(containerSize: proxy.size)
                }
                .onChange(of: model.thumbnailAspectMode) { _, _ in
                    updateGridMetrics(containerSize: proxy.size)
                }
                .onChange(of: gridScrollTargetID) { _, assetID in
                    guard let assetID else { return }
                    scrollProxy.scrollTo(assetID, anchor: .center)
                    gridScrollTargetID = nil
                }
            }
        }
    }

    private func updateGridMetrics(containerSize: CGSize) {
        gridColumnCount = LibraryGridLayout.columnCount(
            containerWidth: containerSize.width,
            density: model.gridDensity
        )
        gridPageItemCount = LibraryGridLayout.pageItemCount(
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            density: model.gridDensity
        )
    }

    private var inspector: some View {
        Group {
            if model.selectedAssetIDs.isEmpty {
                ContentUnavailableView(
                    "未选择照片",
                    systemImage: "sidebar.right",
                    description: Text("选择一张或多张照片以查看信息并编辑人工标签。")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.selectionSummaryTitle)
                            .font(.headline)

                        if let detail = model.inspectorDetail {
                            InspectorPreview(assetID: detail.assetID, model: model)
                            if model.reviewMode == nil {
                                InspectorLocalModelSuggestionSection(model: model)
                                InspectorSuggestionSection(model: model)
                            } else if case let .tagQueue(tagID, displayName) = model.reviewMode {
                                reviewInspectorActions(tagID: tagID, displayName: displayName)
                            }

                            Divider()
                            metadata(detail)
                        } else if !model.assetPendingSuggestions.isEmpty {
                            InspectorSuggestionSection(model: model)
                        }

                        Divider()
                        tagEditor
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("检查器")
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人工标签")
                .font(.headline)

            HStack(spacing: 6) {
                TextField("新标签名称", text: $newTagName)
                    .focused($newTagFieldFocused)
                    .onSubmit { createTag() }
                Button {
                    createTag()
                } label: {
                    Image(systemName: "plus")
                }
                .persistentHelp("创建新标签，并立即将它确认为所选照片所属的标签。")
                .disabled(
                    model.selectedAssetIDs.isEmpty ||
                    TagNameNormalizer.trimUnicodeWhiteSpace(newTagName).isEmpty
                )
            }

            if model.inspectorTags.isEmpty {
                Text("尚无标签。可在上方创建并应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.inspectorTags) { tag in
                    inspectorTagRow(tag)
                }
            }
        }
    }

    private func inspectorTagRow(_ tag: LibraryInspectorTagPresentation) -> some View {
        HStack(spacing: 6) {
            Text(tag.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if tag.decision == .mixed {
                Text("混合")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            tagDecisionButton(
                systemImage: "checkmark",
                label: "确认 \(tag.displayName)",
                isActive: tag.decision == .accepted
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .accept)
            }
            tagDecisionButton(
                systemImage: "xmark",
                label: "拒绝 \(tag.displayName)",
                isActive: tag.decision == .rejected
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .reject)
            }
            tagDecisionButton(
                systemImage: "minus",
                label: "清除 \(tag.displayName) 的决定",
                isActive: tag.decision == .unknown
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .clear)
            }
        }
    }

    private func tagDecisionButton(
        systemImage: String,
        label: String,
        isActive: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : .secondary)
        .background(
            isActive ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .persistentHelp(label)
        .accessibilityLabel(label)
    }

    private func metadata(_ detail: AssetInspectorDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("信息")
                .font(.headline)
            LabeledContent("文件名", value: detail.fileName ?? "—")
            LabeledContent("来源", value: detail.sourceDisplayName)
            LabeledContent("相对位置", value: detail.relativePath ?? "—")
            LabeledContent("媒体", value: detail.mediaKind.displayName)
            LabeledContent("格式", value: detail.mediaType)
            if let width = detail.width, let height = detail.height {
                LabeledContent("尺寸", value: "\(width) × \(height)")
            }
            if let durationMs = detail.durationMs {
                LabeledContent(
                    "时长",
                    value: VideoDurationText.format(milliseconds: durationMs)
                )
            }
            if let bytes = detail.fingerprintSizeBytes {
                LabeledContent(
                    "文件大小",
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                )
            }
            if let createdAt = detail.mediaCreatedAtMs {
                LabeledContent(
                    "拍摄时间",
                    value: Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000)
                        .formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let modifiedAt = detail.mediaModifiedAtMs {
                LabeledContent(
                    "修改时间",
                    value: Date(timeIntervalSince1970: TimeInterval(modifiedAt) / 1_000)
                        .formatted(date: .abbreviated, time: .shortened)
                )
            }
            LabeledContent("状态", value: availabilityText(detail.availability))

            Button {
                Task { await model.openSelectedOriginal() }
            } label: {
                Label(
                    model.isOpeningOriginal
                        ? "正在打开…"
                        : (
                            detail.mediaKind == .video
                                ? "使用系统播放器打开"
                                : "用“预览”打开原图"
                        ),
                    systemImage: detail.mediaKind == .video
                        ? "play.rectangle"
                        : "arrow.up.forward.app"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                detail.availability != .available ||
                    model.selectedAssetIDs.count != 1 ||
                    model.isOpeningOriginal
            )
            .persistentHelp(
                detail.mediaKind == .video
                    ? "以只读方式定位原始视频，并交给系统默认播放器；不会修改视频。"
                    : "以只读方式定位原始照片，并交给 macOS“预览”显示；不会修改原图。"
            )
            .padding(.top, 5)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var libraryToolbarLayoutItems: some View {
        Button {
            layoutState.toggleSidebar()
        } label: {
            LibraryToolbarLabel(
                title: layoutState.isSidebarPresented ? "隐藏侧栏" : "显示侧栏",
                systemImage: "sidebar.left",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .libraryToolbarHelp(
            layoutState.isSidebarPresented ? "隐藏侧栏" : "显示侧栏",
            detail: "显示或隐藏左侧边栏，包含来源、标签分组与导航。"
        )

        Button {
            layoutState.toggleInspector()
        } label: {
            LibraryToolbarLabel(
                title: layoutState.isInspectorPresented ? "隐藏检查器" : "显示检查器",
                systemImage: "sidebar.right",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .libraryToolbarHelp(
            layoutState.isInspectorPresented ? "隐藏检查器" : "显示检查器",
            detail: "显示或隐藏右侧检查器，查看选中照片的详情、标签与操作。"
        )

        if model.isCatalogScanning, selection != .librarySlimming {
            HStack(spacing: 6) {
                if let progress = model.catalogReconcileProgress,
                   let total = progress.total,
                   total > 0
                {
                    ProgressView(value: Double(progress.completed), total: Double(total))
                        .frame(width: 42)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(catalogProgressTitle(model.catalogReconcileProgress))
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(catalogProgressTitle(model.catalogReconcileProgress))
        }

        if let progress = model.sourceThumbnailPrewarmProgress {
            HStack(spacing: 6) {
                if progress.total > 0 {
                    ProgressView(
                        value: Double(progress.completed),
                        total: Double(progress.total)
                    )
                    .frame(width: 42)
                    .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(sourceThumbnailPrewarmTitle(progress))
                    .font(.caption)
                    .lineLimit(1)
                Button("取消") {
                    model.cancelSourceThumbnailPrewarm()
                }
                .controlSize(.small)
                .persistentHelp("停止当前缩略图预热；已经生成的缓存会保留。")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sourceThumbnailPrewarmProgress")
            .accessibilityLabel(sourceThumbnailPrewarmTitle(progress))
        }
    }

    @ViewBuilder
    private var libraryToolbarPersonalizationItems: some View {
        if model.supportsPersonalModelRebuild {
            Button {
                Task { await model.rebuildPersonalModel() }
            } label: {
                if model.isRebuildingPersonalModel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    LibraryToolbarLabel(
                        title: "重建个人模型",
                        systemImage: "brain.head.profile",
                        displayMode: toolbarDisplayModeSettings.displayMode
                    )
                }
            }
            .disabled(
                model.isRebuildingPersonalModel
                    || model.isRebuildingPersonalAdamWModel
                    || model.isGeneratingPersonalLibrarySuggestions
            )
            .libraryToolbarHelp(
                "重建个人模型",
                detail: "先在左侧选择要训练的标签；有多选时只使用选中照片上这些标签的确认样本，无多选时使用全库这些标签的全部确认样本。会自动为本批样本补齐本地 embedding（仅用本机预览）。"
            )
        }

        if model.supportsPersonalAdamWModelRebuild {
            Button {
                Task { await model.rebuildPersonalAdamWModel() }
            } label: {
                if model.isRebuildingPersonalAdamWModel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    LibraryToolbarLabel(
                        title: "训练超级个人模型",
                        systemImage: "brain.head.profile.fill",
                        displayMode: toolbarDisplayModeSettings.displayMode
                    )
                }
            }
            .disabled(
                model.isRebuildingPersonalModel
                    || model.isRebuildingPersonalAdamWModel
                    || model.isGeneratingPersonalLibrarySuggestions
            )
            .libraryToolbarHelp(
                "训练超级个人模型",
                detail: "先在左侧选择要训练的标签；冻结 DINO + AdamW 线性头，多 epoch / 早停；仍只要正样本。与人脑质心模型并存、互不覆盖。多选只限样本照片。"
            )
        }

        if model.supportsAppPersonalSampleSuggestions {
            Button {
                Task { await model.generateAppPersonalSampleSuggestions() }
            } label: {
                if model.isGeneratingAppPersonalSampleSuggestions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    LibraryToolbarLabel(
                        title: "抽 \(model.maxPendingSuggestionsPerTag) 张生成建议",
                        systemImage: "wand.and.stars",
                        displayMode: toolbarDisplayModeSettings.displayMode
                    )
                }
            }
            .disabled(!model.canGenerateAppPersonalSampleSuggestions)
            .libraryToolbarHelp(
                "生成建议",
                detail: "有多选时：对选中照片（最多 \(model.maxPendingSuggestionsPerTag) 张）生成建议；"
                    + "无多选时：从库中抽最多 \(model.maxPendingSuggestionsPerTag) 张。"
                    + "写入待审核队列后可用 P 接受 / X 拒绝。"
            )
        }

        if model.supportsSelectedAssetEmbeddingCache {
            Button {
                Task { await model.cacheSelectedAssetEmbedding() }
            } label: {
                if model.isCachingSelectedAssetEmbedding {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    LibraryToolbarLabel(
                        title: "准备选中照片特征",
                        systemImage: "sparkles",
                        displayMode: toolbarDisplayModeSettings.displayMode
                    )
                }
            }
            .disabled(!model.canCacheSelectedAssetEmbedding)
            .libraryToolbarHelp(
                "准备选中照片特征",
                detail: "为当前选中的照片生成或命中跳过本地模型缓存；重建个人模型会按选中/历史样本范围自行准备所需特征。"
            )
        }

        if model.supportsLibrarySlimming {
            Button {
                Task { await model.findLibrarySlimmingFromSelection() }
            } label: {
                LibraryToolbarLabel(
                    title: "在图库瘦身中查找",
                    systemImage: "square.stack.3d.up",
                    displayMode: toolbarDisplayModeSettings.displayMode
                )
            }
            .disabled(!model.canFindLibrarySlimmingFromSelection)
            .libraryToolbarHelp(
                "在图库瘦身中查找",
                detail: "以当前多选为种子，在图库（或当前筛选）中查找相同与相似照片。"
            )
        }
    }

    @ViewBuilder
    private var libraryToolbarBrowseAndActionItems: some View {
        filterMenu
        sortMenu

        if model.reviewMode == nil,
           !model.items.isEmpty || selection == .librarySlimming
        {
            LibraryGridDensityPicker(
                selection: Binding(
                    get: { model.gridDensity },
                    set: { model.setGridDensity($0) }
                ),
                displayMode: toolbarDisplayModeSettings.displayMode
            )
            LibraryThumbnailAspectModeButton(
                selection: Binding(
                    get: { model.thumbnailAspectMode },
                    set: { model.setThumbnailAspectMode($0) }
                ),
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }

        Button {
            Task { await model.undoLastTagMutation() }
        } label: {
            LibraryToolbarLabel(
                title: "撤销标签操作",
                systemImage: "arrow.uturn.backward",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .disabled(!model.canUndoTagMutation)
        .libraryToolbarHelp(
            "撤销标签操作",
            detail: "撤销最近一次对标签的创建、确认、拒绝或清除操作。"
        )

        if model.canUndoReviewMutation {
            Button {
                Task { await model.undoLastReviewMutation() }
            } label: {
                LibraryToolbarLabel(
                    title: "撤销审核操作",
                    systemImage: "arrow.uturn.backward.circle",
                    displayMode: toolbarDisplayModeSettings.displayMode
                )
            }
            .libraryToolbarHelp(
                "撤销审核操作",
                detail: "撤销最近一次在审核队列中的接受或拒绝操作。"
            )
        }

        Button {
            Task { await model.connectFolder() }
        } label: {
            LibraryToolbarLabel(
                title: "连接文件夹",
                systemImage: "folder.badge.plus",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .disabled(model.isBusy)
        .libraryToolbarHelp(
            "连接文件夹",
            detail: "选择本地文件夹作为新的照片来源；ImageAll 会索引其中的照片，不会修改原文件。"
        )

        Button {
            Task { await model.exportPortableUserData() }
        } label: {
            LibraryToolbarLabel(
                title: "导出用户数据",
                systemImage: "square.and.arrow.up",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .disabled(model.isBusy || model.isExportingPortableData)
        .libraryToolbarHelp(
            "导出用户数据",
            detail: "导出标签、审核记录与个人模型等用户数据，便于备份或迁移。"
        )

        Button {
            showPreviewCachePanel = true
            Task { await model.refreshPreviewCacheUsage() }
        } label: {
            LibraryToolbarLabel(
                title: "预览缓存",
                systemImage: "internaldrive",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .popover(isPresented: $showPreviewCachePanel) {
            previewCachePanel
        }
        .libraryToolbarHelp(
            "预览缓存",
            detail: "查看预览缓存占用空间，并可清理不再需要的缓存文件。"
        )

        Button {
            activeSheet = .commandPalette
        } label: {
            LibraryToolbarLabel(
                title: "命令",
                systemImage: "command",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .keyboardShortcut("k", modifiers: .command)
        .libraryToolbarHelp("命令", detail: "打开命令面板，快速执行导航与操作（⌘K）。")

        Button {
            showJobActivityPanel = true
            Task { await model.refreshJobActivity() }
        } label: {
            LibraryToolbarLabel(
                title: "活动",
                systemImage: "clock.arrow.circlepath",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .popover(isPresented: $showJobActivityPanel) {
            jobActivityPanel
        }
        .libraryToolbarHelp(
            "活动",
            detail: "查看后台任务进度，例如扫描、建议生成与个人模型训练。"
        )

        Button {
            Task { await model.rescan() }
        } label: {
            LibraryToolbarLabel(
                title: model.rescanToolbarTitle,
                systemImage: "arrow.clockwise",
                displayMode: toolbarDisplayModeSettings.displayMode
            )
        }
        .disabled(model.isBusy || !model.canRescan)
        .libraryToolbarHelp(
            model.rescanToolbarTitle,
            detail: "重新扫描当前来源或同步 Apple Photos，更新索引与可用状态。"
        )
    }

    private var filterMenu: some View {
        Menu {
            Button {
                Task { await model.setTagPresence(.any) }
            } label: {
                Label("全部照片", systemImage: model.tagPresence == .any ? "checkmark" : "circle")
            }
            .persistentHelp("取消“无标签”条件，显示当前范围内有标签和无标签的照片。")
            Button {
                Task { await model.setTagPresence(.untagged) }
            } label: {
                Label("无标签", systemImage: model.tagPresence == .untagged ? "checkmark" : "circle")
            }
            .persistentHelp("只显示尚未设置任何人工标签决定的照片。")

            if !model.tags.isEmpty {
                Divider()
                ForEach(model.tags, id: \.id) { tag in
                    Menu(tag.displayName) {
                        tagFilterButton(tag: tag, decision: .accepted, title: "已确认")
                        tagFilterButton(tag: tag, decision: .rejected, title: "已拒绝")
                        Button("不筛选此标签") {
                            Task { await model.setTagDecisionFilter(tagID: tag.id, decision: nil) }
                        }
                        .persistentHelp("移除“\(tag.displayName)”的确认或拒绝筛选条件。")
                    }
                }
            }

            if model.selectedTagFilterIDs.count >= 1 {
                Divider()
                Button {
                    Task { await model.setTagMatchMode(.all) }
                } label: {
                    Label("全部标签（ALL）", systemImage: model.tagMatchMode == .all ? "checkmark" : "circle")
                }
                .persistentHelp("照片必须同时符合全部已选标签条件才会显示。")
                Button {
                    Task { await model.setTagMatchMode(.any) }
                } label: {
                    Label("任一标签（ANY）", systemImage: model.tagMatchMode == .any ? "checkmark" : "circle")
                }
                .persistentHelp("照片符合任意一个已选标签条件就会显示。")
            }

            if model.hasActiveTagFilters {
                Divider()
                Button("清除标签筛选") {
                    Task { await model.clearTagFilters() }
                }
                .persistentHelp("清除全部标签条件，但保留状态和文件格式筛选。")
            }

            Divider()
            Menu("可用状态") {
                Button {
                    Task { await model.clearAvailabilityFilters() }
                } label: {
                    Label(
                        "全部状态",
                        systemImage: model.selectedAvailabilities.isEmpty ? "checkmark" : "circle"
                    )
                }
                .persistentHelp("清除照片可用状态条件，显示所有状态。")
                Divider()
                availabilityFilterButton(.available, title: "可用")
                availabilityFilterButton(.missing, title: "文件缺失")
                availabilityFilterButton(.unreadable, title: "不可读取")
                availabilityFilterButton(.unsupported, title: "格式不支持")
            }
            Menu("文件格式") {
                Button {
                    Task { await model.clearMediaTypeFilters() }
                } label: {
                    Label(
                        "全部格式",
                        systemImage: model.selectedMediaTypes.isEmpty ? "checkmark" : "circle"
                    )
                }
                .persistentHelp("清除文件格式条件，显示所有支持格式。")
                Divider()
                ForEach(Self.mediaFormatFilterOptions, id: \.title) { option in
                    Button {
                        Task { await model.toggleMediaTypeFilterGroup(option.mediaTypes) }
                    } label: {
                        Label(
                            option.title,
                            systemImage: model.isMediaTypeFilterGroupSelected(option.mediaTypes)
                                ? "checkmark"
                                : "circle"
                        )
                    }
                    .persistentHelp("切换“\(option.title)”格式组是否包含在当前筛选中。")
                }
            }
        } label: {
            switch toolbarDisplayModeSettings.displayMode {
            case .iconOnly:
                Image(
                    systemName: activeFilterCount == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            case .iconAndTitle:
                Label(
                    filterMenuTitle,
                    systemImage: activeFilterCount == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
        }
        .libraryToolbarHelp(
            "筛选",
            detail: "按标签、可用状态与文件格式筛选当前照片列表。"
        )
    }

    private var filterMenuTitle: String {
        if let summary = model.tagFilterSummaryText() {
            return summary
        }
        return activeFilterCount == 0 ? "筛选" : "筛选 \(activeFilterCount)"
    }

    private func tagFilterSummaryBar(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            if model.selectedTagFilterIDs.count >= 1 {
                Picker("标签关系", selection: Binding(
                    get: { model.tagMatchMode },
                    set: { newMode in Task { await model.setTagMatchMode(newMode) } }
                )) {
                    Text("或").tag(TagMatchMode.any)
                    Text("且").tag(TagMatchMode.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 120)
                .persistentHelp("选择标签条件是满足任意一个“或”，还是必须全部满足“且”。")
            }
            Button("清除筛选") {
                Task { await model.clearTagFilters() }
            }
            .buttonStyle(.borderless)
            .persistentHelp("清除当前全部标签筛选条件，恢复显示当前来源范围内的照片。")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var sortMenu: some View {
        Menu {
            sortButton(.newest, title: "最新优先")
            sortButton(.oldest, title: "最早优先")
            sortButton(.fileNameAscending, title: "文件名升序")
        } label: {
            switch toolbarDisplayModeSettings.displayMode {
            case .iconOnly:
                Image(systemName: "arrow.up.arrow.down")
            case .iconAndTitle:
                Label(sortTitle(model.sort), systemImage: "arrow.up.arrow.down")
            }
        }
        .libraryToolbarHelp(
            "排序",
            detail: "更改照片列表的排序方式：最新优先、最早优先或文件名升序。"
        )
    }

    private func sortButton(_ sort: AssetPageSort, title: String) -> some View {
        Button {
            Task { await model.setSort(sort) }
        } label: {
            Label(title, systemImage: model.sort == sort ? "checkmark" : "circle")
        }
        .persistentHelp("按“\(title)”重新排列当前照片列表。")
    }

    private func sortTitle(_ sort: AssetPageSort) -> String {
        switch sort {
        case .newest: "最新优先"
        case .oldest: "最早优先"
        case .fileNameAscending: "文件名升序"
        }
    }

    private func catalogProgressTitle(_ progress: CatalogReconcileProgress?) -> String {
        guard let progress else { return "正在准备扫描" }
        let source = progress.sourceDisplayName
            ?? (progress.sourceKind == .photos ? "Apple Photos" : "文件夹")
        if let total = progress.total, total > 0 {
            return "\(source) \(progress.completed.formatted()) / \(total.formatted())"
        }
        if progress.completed > 0 {
            return "\(source) 已检查 \(progress.completed.formatted()) 张"
        }
        return "正在扫描 \(source)"
    }

    private func sourceThumbnailPrewarmTitle(_ progress: SourceThumbnailPrewarmProgress) -> String {
        if progress.total > 0 {
            return "预热 \(progress.sourceDisplayName) \(progress.completed.formatted()) / \(progress.total.formatted())"
        }
        return "正在列出 \(progress.sourceDisplayName)…"
    }

    private func availabilityFilterButton(
        _ availability: AssetAvailability,
        title: String
    ) -> some View {
        Button {
            Task { await model.toggleAvailabilityFilter(availability) }
        } label: {
            Label(
                title,
                systemImage: model.selectedAvailabilities.contains(availability) ? "checkmark" : "circle"
            )
        }
        .persistentHelp("切换“\(title)”可用状态是否包含在当前筛选中。")
    }

    private func tagFilterButton(
        tag: TagListItem,
        decision: PersistableTagDecision,
        title: String
    ) -> some View {
        Button {
            Task { await model.setTagDecisionFilter(tagID: tag.id, decision: decision) }
        } label: {
            Label(
                title,
                systemImage: model.tagFilterDecision(for: tag.id) == decision ? "checkmark" : "circle"
            )
        }
        .persistentHelp("只显示“\(tag.displayName)”标签被标记为“\(title)”的照片。")
    }

    private var activeFilterCount: Int {
        model.selectedTagFilterIDs.count +
        model.excludedTagFilterIDs.count +
        (model.tagPresence == .any ? 0 : 1) +
        model.selectedAvailabilities.count +
        Self.mediaFormatFilterOptions.filter {
            model.isMediaTypeFilterGroupSelected($0.mediaTypes)
        }.count
    }

    private func createTag() {
        let candidate = newTagName
        guard !TagNameNormalizer.trimUnicodeWhiteSpace(candidate).isEmpty else { return }
        Task {
            await model.requestCreateAndAcceptTag(named: candidate)
            if model.notice == nil {
                newTagName = ""
            }
        }
    }

    private func noticeBar(_ notice: LibraryWorkspaceNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: noticeIcon(notice))
            if case let .tagBatchMutationApplied(count, tagName, action) = notice {
                Text(Self.tagBatchMutationNoticeText(count: count, tagName: tagName, action: action))
                    .font(.caption)
                Spacer()
                if model.canUndoTagMutation {
                    Button("撤销") {
                        Task { await model.undoLastTagMutation() }
                    }
                    .buttonStyle(.plain)
                    .persistentHelp("撤销刚刚完成的这次标签操作。")
                }
                Button("关闭") { model.dismissNotice() }
                    .buttonStyle(.plain)
                    .persistentHelp("关闭这条状态提示。")
            } else {
                Text(Self.noticeText(notice))
                    .font(.caption)
                Spacer()
                Button("关闭") { model.dismissNotice() }
                    .buttonStyle(.plain)
                    .persistentHelp("关闭这条状态提示。")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func noticeIcon(_ notice: LibraryWorkspaceNotice) -> String {
        switch notice {
        case .selectionHiddenByFilter:
            "line.3.horizontal.decrease.circle"
        case .presetTagsInstalled, .presetTagsAlreadyAvailable,
             .portableExportCompleted, .previewCacheCleared,
             .photosOriginalStorageCleared,
             .sourceThumbnailPrewarmCompleted,
             .sourceThumbnailPrewarmCancelled,
             .appStorageLocationRequiresRestart,
             .personalModelRebuildCompleted, .personalAdamWRebuildCompleted,
             .selectedAssetEmbeddingCached,
             .selectedAssetEmbeddingBatchCompleted,
             .personalSampleSuggestionsCompleted,
             .featureKnnSuggestionsCompleted,
             .personalTagLibrarySuggestionsCompleted,
             .personalAdamWTagLibrarySuggestionsCompleted,
             .suggestionThresholdPruned,
             .tagBatchMutationApplied, .photosAlreadyConnected,
             .photosSyncQueued, .photosFullRepairQueued:
            "checkmark.circle"
        default:
            "exclamationmark.triangle"
        }
    }

    static func noticeText(_ notice: LibraryWorkspaceNotice) -> String {
        switch notice {
        case .selectionHiddenByFilter: "当前选择已被筛选条件隐藏，因此已清除。"
        case let .presetTagsInstalled(createdCount): "已添加 " + String(createdCount) + " 个常用标签；未给照片应用标签。"
        case .presetTagsAlreadyAvailable: "常用标签已经齐全；未修改照片或人工标签。"
        case .invalidTagName: "标签名称无效。"
        case .duplicateTag: "已有同名标签。"
        case .invalidTagGroupName: "分组名称无效。"
        case .duplicateTagGroup: "已有同名分组。"
        case .systemTagGroupProtected: "系统默认分组不可修改或删除。"
        case .tagMutationFailed: "标签操作未保存，请重试。"
        case .tagSelectionRefreshFailed: "标签已保存，但当前选择刷新失败；请重新选择照片后继续。"
        case .sourceActionFailed: "来源操作未完成。原照片没有被修改，请重试。"
        case .backgroundScanFailed: "后台扫描未完成，已索引的照片仍可继续浏览。"
        case .photosAuthorizationRequired: "ImageAll 当前没有照片访问权限。授权后请重新检查并同步。"
        case .reviewActionFailed: "建议任务操作未完成，请重试。"
        case .reviewJobConflict: "该标签已有进行中的建议任务。"
        case let .insufficientSuggestionSamples(positive, negative):
            "还需确认 \(positive) 张、标记不属于 \(negative) 张。"
        case let .reviewMutationApplied(count, tagName):
            "已处理 \(count) 条“\(tagName)”建议"
        case let .tagBatchMutationApplied(count, tagName, action):
            tagBatchMutationNoticeText(count: count, tagName: tagName, action: action)
        case .photosAlreadyConnected:
            "Apple Photos 已连接。"
        case .photosSyncQueued:
            "已开始增量同步 Apple Photos。"
        case .photosFullRepairQueued:
            "完整修复扫描已在后台开始；扫描期间仍可浏览已有索引。"
        case let .portableExportCompleted(bundleName, recordCount):
            "已导出 \(recordCount) 条记录到“\(bundleName)”。"
        case .portableExportDestinationOverlapsSource:
            "导出位置不能与已添加的文件夹来源重叠，请选择其他文件夹。"
        case .portableExportIsolationIndeterminate:
            "无法确认导出位置与来源隔离，尚未开始导出。请重新授权来源或选择其他位置；仍失败时请停止导出。"
        case .portableExportFailed:
            "用户数据导出未完成，现有资料没有被修改。请重试。"
        case let .previewCacheCleared(removedEntries, partialReclaim):
            partialReclaim
                ? "已使 \(removedEntries) 个预览缓存条目失效，部分磁盘空间待后续回收。"
                : "已清理 \(removedEntries) 个预览缓存条目。"
        case .previewCacheActionFailed:
            "预览缓存操作未完成。原照片、人工标签和个性化数据没有被修改。"
        case let .photosOriginalStorageCleared(removedEntries, partialReclaim):
            partialReclaim
                ? "已清理 \(removedEntries) 个长期原图副本，部分磁盘空间待后续重试。"
                : "已清理 \(removedEntries) 个长期原图副本。"
        case .photosOriginalStorageActionFailed:
            "长期原图清理未完成。Apple Photos、人工标签和已计算的相同检测结果没有被修改。"
        case let .sourceThumbnailPrewarmCompleted(sourceDisplayName, warmed, failed, total):
            if failed == 0 {
                "已为“\(sourceDisplayName)”预热 \(warmed)/\(total) 张缩略图到磁盘缓存。"
            } else {
                "已为“\(sourceDisplayName)”预热 \(warmed)/\(total) 张缩略图（失败 \(failed) 张）；已写入磁盘的条目可跨启动复用。"
            }
        case let .sourceThumbnailPrewarmCancelled(sourceDisplayName, completed, total):
            "已取消“\(sourceDisplayName)”缩略图预热（\(completed)/\(total)）。已写入磁盘的条目仍会保留。"
        case .sourceThumbnailPrewarmFailed:
            "来源缩略图预热未能开始。浏览和已有缓存不受影响，请稍后重试。"
        case .appStorageLocationRequiresRestart:
            "外置应用存储位置已保存；重新启动 ImageAll 后会迁移现有资料与全部缓存。"
        case .appStorageLocationActionFailed:
            "外置应用存储位置未更改。请确认所选目录可写且不是软链接或文件包。"
        case .jobActivityActionFailed:
            "任务操作未完成，已重新读取当前状态。请重试。"
        case let .personalModelRebuildCompleted(tagCount, sampleCount):
            "个人模型已从 \(tagCount) 个标签的 \(sampleCount) 张人工样本重建并确认生效。"
        case .personalModelRebuildTagSelectionRequired:
            "请先在左侧选择要训练的标签；不会训练未选中的标签（例如地点类标签可不选）。"
        case .personalModelRebuildNotReady:
            "所选标签中尚无可训练项；每个标签至少需要 2 张确认样本（有多选时只计选中照片上的确认样本）。"
        case .personalModelRebuildPreviewUnavailable:
            "训练样本中有照片尚未在本机可用；未下载云端原图，也未替换现有个人模型。"
        case .personalModelRebuildCacheUnavailable:
            "训练样本的本地 embedding 未能准备完成；现有个人模型未替换。可确认本机预览可用后重试重建。"
        case .personalModelRebuildServiceUnavailable:
            "个人模型服务当前不可用；现有模型和标准建议不受影响。"
        case .personalModelRebuildFailed:
            "个人模型重建未完成；现有模型保持不变，请核对样本后重试。"
        case let .personalAdamWRebuildCompleted(tagCount, sampleCount):
            "超级个人模型（AdamW）已从 \(tagCount) 个标签的 \(sampleCount) 张人工样本训练并确认生效。"
        case .personalAdamWRebuildTagSelectionRequired:
            "请先在左侧选择要训练的标签；超级人脑不会训练未选中的标签。"
        case .personalAdamWRebuildNotReady:
            "所选标签中尚无可训练项；超级人脑同样要求每个标签至少 2 张确认样本。"
        case .personalAdamWRebuildFailed:
            "超级个人模型训练未完成；现有超级模型保持不变，请核对样本后重试。"
        case .selectedAssetEmbeddingCached:
            "已为当前照片生成身份匹配的本地模型缓存。"
        case let .selectedAssetEmbeddingBatchCompleted(prepared, skipped, cloudOnly, failed):
            selectedAssetEmbeddingBatchNoticeText(
                prepared: prepared,
                skipped: skipped,
                cloudOnly: cloudOnly,
                failed: failed
            )
        case .selectedAssetEmbeddingModelUnavailable:
            "App 内模型尚未启用或当前不可用；没有读取照片，浏览和人工标签不受影响。"
        case .selectedAssetEmbeddingPreviewUnavailable:
            "当前照片尚未在本机可用；未自动下载云端原图，浏览和人工标签不受影响。"
        case .selectedAssetEmbeddingFailed:
            "当前照片的本地模型缓存未生成；浏览和人工标签不受影响。"
        case let .personalSampleSuggestionsCompleted(checked, suggested, skipped):
            if suggested > 0 {
                "已抽检 \(checked) 张照片：写入 \(suggested) 条待审核建议，跳过 \(skipped) 张。请打开「待审核建议」按 P 接受 / X 拒绝。"
            } else {
                "已抽检 \(checked) 张照片：没有新的待审核建议（命中照片此前已审核过），跳过 \(skipped) 张。"
            }
        case .personalSampleSuggestionsNotReady:
            "当前没有可用的个人模型，或抽检候选为空；请先重建个人模型后再试。"
        case .personalSampleSuggestionsModelUnavailable:
            "App 内模型尚未启用或当前不可用；没有写入建议，浏览和人工标签不受影响。"
        case .personalSampleSuggestionsFailed:
            "抽检建议未完成；现有审核队列保持不变，请稍后重试。"
        case let .featureKnnSuggestionsCompleted(
            tagName,
            candidates,
            aboveThreshold,
            reviewable,
            skipped
        ):
            "特征向量“\(tagName)”生成完成：高于阈值 \(aboveThreshold) 条 / 候选 \(candidates) 条，当前待审核 \(reviewable) 条，跳过 \(skipped) 条。"
        case let .personalTagLibrarySuggestionsCompleted(
            tagName,
            candidates,
            aboveThreshold,
            inserted,
            skipped
        ):
            "个人模型“\(tagName)”生成完成：高于阈值 \(aboveThreshold) 条 / 候选 \(candidates) 条，实际写入 \(inserted) 条，跳过 \(skipped) 条。"
        case .personalTagLibrarySuggestionsNotReady:
            "当前没有可用的个人模型；请先点人脑图标重建后再试。"
        case .personalTagLibrarySuggestionsTagNotInModel:
            "当前个人模型不含该标签；请先用该标签的确认样本点人脑重建。"
        case .personalTagLibrarySuggestionsModelUnavailable:
            "App 内模型尚未启用或当前不可用；没有写入建议，浏览和人工标签不受影响。"
        case .personalTagLibrarySuggestionsFailed:
            "个人模型全库建议未完成；现有审核队列保持不变，请稍后重试。"
        case let .personalAdamWTagLibrarySuggestionsCompleted(
            tagName,
            candidates,
            aboveThreshold,
            inserted,
            skipped
        ):
            "超级个人模型“\(tagName)”生成完成：高于阈值 \(aboveThreshold) 条 / 候选 \(candidates) 条，实际写入 \(inserted) 条，跳过 \(skipped) 条。"
        case .personalAdamWTagLibrarySuggestionsNotReady:
            "当前没有可用的超级个人模型；请先点超级人脑图标训练后再试。"
        case .personalAdamWTagLibrarySuggestionsTagNotInModel:
            "当前超级个人模型不包含该标签；请先用超级人脑把该标签纳入训练后再试。"
        case .personalAdamWTagLibrarySuggestionsFailed:
            "超级个人模型建议未完成；现有审核队列保持不变，请稍后重试。"
        case let .suggestionThresholdPruned(tagName, methodName, deletedCount):
            "已按当前“\(methodName)”门槛刷新“\(tagName)”待审队列，删除 \(deletedCount) 条。"
        case .suggestionThresholdUpdateFailed:
            "建议阈值未能保存，请重试。"
        case .originalOpenFailed:
            "无法用“预览”打开原图。请确认来源仍可用、授权有效且照片已可从本机读取。"
        }
    }

    private static func selectedAssetEmbeddingBatchNoticeText(
        prepared: Int,
        skipped: Int,
        cloudOnly: Int,
        failed: Int
    ) -> String {
        var parts: [String] = []
        if prepared > 0 { parts.append("新准备 \(prepared) 张") }
        if skipped > 0 { parts.append("命中跳过 \(skipped) 张") }
        if cloudOnly > 0 { parts.append("仅云端跳过 \(cloudOnly) 张") }
        if failed > 0 { parts.append("失败 \(failed) 张") }
        if parts.isEmpty {
            return "选中照片特征未准备；浏览和人工标签不受影响。"
        }
        return "选中照片特征已处理：\(parts.joined(separator: "，"))。"
    }

    private func reviewInspectorActions(tagID: UUID, displayName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 建议")
                .font(.headline)
            Text("当前标签：\(displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("确认属于 (P)") {
                    Task { await model.applyReviewDecision(action: .accept) }
                }
                .persistentHelp("确认所选照片属于当前审核标签，并进入下一项；快捷键 P。")
                Button("不属于 (X)") {
                    Task { await model.applyReviewDecision(action: .reject) }
                }
                .persistentHelp("确认所选照片不属于当前审核标签，并进入下一项；快捷键 X。")
                Button("稍后 (U)") {
                    Task { await model.deferReviewSelection() }
                }
                .persistentHelp("暂不处理所选照片并移到队列后面；快捷键 U。")
            }
            .disabled(model.selectedAssetIDs.isEmpty)
        }
    }

    private func availabilityText(_ availability: AssetAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .missing: "文件缺失"
        case .unreadable: "不可读取"
        case .unsupported: "格式不支持"
        case .recycled: "回收站"
        }
    }

    private func sourceIcon(_ state: SourceState) -> String {
        switch state {
        case .active: return "folder"
        case .unavailable: return "externaldrive.badge.exclamationmark"
        case .authorizationRequired: return "lock.trianglebadge.exclamationmark"
        case .disabled: return "pause.circle"
        }
    }

    private func sourceStatusText(_ state: SourceState) -> String? {
        switch state {
        case .active: return nil
        case .unavailable: return "离线"
        case .authorizationRequired: return "需授权"
        case .disabled: return "已停用"
        }
    }

    private func sourceHelpText(_ state: SourceState) -> String {
        switch state {
        case .active: return "来源可用"
        case .unavailable: return "来源当前离线"
        case .authorizationRequired: return "需要重新授权此来源"
        case .disabled: return "来源已停用，已索引照片和人工标签仍保留"
        }
    }

    static func tagBatchMutationNoticeText(
        count: Int,
        tagName: String,
        action: LibraryTagMutationFeedbackKind
    ) -> String {
        let verb: String = switch action {
        case .accepted: "确认"
        case .rejected: "拒绝"
        case .cleared: "清除"
        case .createdAndApplied: "创建并应用"
        }
        return "已为 \(count) 张照片\(verb)“\(tagName)”"
    }

    private func errorTitle(_ error: LibraryWorkspaceSafeError) -> String {
        switch error {
        case .connectionFailed: return "无法连接照片来源"
        case .scanFailed: return "扫描未完成"
        case .catalogFailed: return "无法读取图库"
        }
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SinglePhotoReviewView: View {
    let item: ReviewQueueItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            SinglePhotoNavigationBar(model: model)
            Divider()
            HStack(spacing: 12) {
                Button("属于 (P)", systemImage: "checkmark.circle") {
                    Task { await model.applyReviewDecision(action: .accept) }
                }
                .persistentHelp("确认当前照片属于审核标签，并进入下一张；快捷键 P。")
                Button("不属于 (X)", systemImage: "xmark.circle") {
                    Task { await model.applyReviewDecision(action: .reject) }
                }
                .persistentHelp("确认当前照片不属于审核标签，并进入下一张；快捷键 X。")
                Button("稍后 (U)", systemImage: "arrow.right.circle") {
                    Task { await model.deferReviewSelection() }
                }
                .persistentHelp("暂不处理当前照片并移到队列后面；快捷键 U。")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(model.selectedAssetIDs.isEmpty)
            .accessibilityIdentifier("singlePhotoReviewActions")
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("singlePhotoView")
        .accessibilityLabel(item.fileName ?? "照片")
        .task(id: item.assetID) {
            image = nil
            guard item.availability == .available,
                  let data = await model.previewData(assetID: item.assetID)
            else { return }
            image = NSImage(data: data)
        }
    }
}

private struct SinglePhotoView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            SinglePhotoNavigationBar(model: model)
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
                if item.mediaKind == .video {
                    VStack {
                        Spacer()
                        Button {
                            Task { await model.openSelectedOriginal() }
                        } label: {
                            Label("使用系统播放器打开", systemImage: "play.fill")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(item.availability != .available || model.isOpeningOriginal)
                        .padding(.bottom, 28)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("singlePhotoView")
        .accessibilityLabel(item.fileName ?? item.mediaKind.displayName)
        .task(id: item.assetID) {
            image = nil
            guard item.availability == .available,
                  let data = await model.previewData(assetID: item.assetID)
            else {
                return
            }
            image = NSImage(data: data)
        }
    }

    private var emptySymbol: String {
        if case let .available(assetID) = model.cloudPreviewState, assetID == item.assetID {
            return "icloud.and.arrow.down"
        }
        if case let .downloading(assetID, _) = model.cloudPreviewState, assetID == item.assetID {
            return "icloud.and.arrow.down"
        }
        if case let .failed(assetID) = model.cloudPreviewState, assetID == item.assetID {
            return "exclamationmark.icloud"
        }
        return placeholderIcon
    }

    private var placeholderIcon: String {
        switch item.availability {
        case .available: return "photo"
        case .missing: return "questionmark.folder"
        case .unreadable: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        case .recycled: return "trash"
        }
    }
}

private struct SinglePhotoNavigationBar: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        if let navigation = model.singlePhotoNavigation {
            HStack(spacing: 12) {
                Button("返回网格", systemImage: "square.grid.2x2") {
                    model.closeSinglePhotoView()
                }
                .persistentHelp("关闭单图查看并返回当前照片网格；也可按 Esc。")

                Spacer()

                VStack(spacing: 2) {
                    Text(navigation.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .persistentHelp("当前照片文件名：\(navigation.fileName)")
                    Text("\(navigation.position) / \(navigation.loadedCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "第 \(navigation.position) 张，已载入 \(navigation.loadedCount) 张"
                        )
                }

                Spacer()

                Button("上一张", systemImage: "chevron.left") {
                    Task { await model.moveSinglePhotoSelection(by: -1) }
                }
                .disabled(!navigation.canMovePrevious)
                .persistentHelp("显示当前列表中的上一张照片。")

                Button("下一张", systemImage: "chevron.right") {
                    Task { await model.moveSinglePhotoSelection(by: 1) }
                }
                .disabled(!navigation.canMoveNext)
                .persistentHelp("显示当前列表中的下一张照片。")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("singlePhotoNavigationBar")
        }
    }
}

private struct AssetThumbnailView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var isCloudOnly = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: model.thumbnailAspectMode.imageContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: emptyThumbnailSymbol)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomTrailing) {
                let decisionCount = item.acceptedTagCount + item.rejectedTagCount
                if decisionCount > 0 {
                    Label("\(decisionCount)", systemImage: "tag.fill")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.mediaKind == .video {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        if let durationMs = item.durationMs {
                            Text(VideoDurationText.format(milliseconds: durationMs))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(6)
                }
            }
            .accessibilityLabel(item.fileName ?? item.mediaKind.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .aspectRatio(thumbnailFrameAspectRatio, contentMode: .fit)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { onOpen() }
                .exclusively(
                    before: TapGesture().onEnded { onSelect() }
                )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint(
            item.mediaKind == .video
                ? "选择视频；双击或选择后按空格查看代表缩略图和播放入口"
                : "选择照片；双击或选择后按空格查看单张照片"
        )
        .persistentHelp(LibraryAssetDetailText.hoverText(item))
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: "打开单图预览") {
            onOpen()
        }
        .task(id: thumbnailLoadID) {
            await loadGridThumbnailWhileVisible()
        }
    }

    private func loadGridThumbnailWhileVisible() async {
        isCloudOnly = false
        guard item.availability == .available else {
            image = nil
            return
        }

        if let cached = model.cachedThumbnailData(for: item.assetID),
           let cachedImage = LibraryGridThumbnailImageFactory.image(from: cached)
        {
            image = cachedImage
            return
        }

        var transientAttempts = 0
        while !Task.isCancelled {
            switch await model.loadThumbnailResultWithRetry(assetID: item.assetID) {
            case let .loaded(data):
                guard !Task.isCancelled else { return }
                if let decoded = LibraryGridThumbnailImageFactory.image(from: data) {
                    model.rememberThumbnailData(data, for: item.assetID)
                    image = decoded
                    return
                }
                transientAttempts += 1
                if transientAttempts >= 4 {
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            case .cloudOnly:
                guard !Task.isCancelled else { return }
                isCloudOnly = true
                return
            case .unavailable:
                return
            case .cancelled:
                if Task.isCancelled {
                    return
                }
                // Remount/scroll cancellation — retry briefly while still visible.
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled {
                    return
                }
            case .failed:
                // Exhausted transient retries. Stop hammering the loader so
                // sidebar navigation stays responsive; scrolling away and back
                // remounts the cell task and tries again.
                transientAttempts += 1
                if transientAttempts >= 2 {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private var thumbnailLoadID: AssetThumbnailLoadID {
        let usesDownloadedCloudPreview: Bool
        if case let .downloaded(assetID, _) = model.cloudPreviewState {
            usesDownloadedCloudPreview = assetID == item.assetID
        } else {
            usesDownloadedCloudPreview = false
        }
        return AssetThumbnailLoadID(
            assetID: item.assetID,
            usesDownloadedCloudPreview: usesDownloadedCloudPreview,
            cacheVersion: model.thumbnailCacheVersion(for: item.assetID)
        )
    }

    private var thumbnailFrameAspectRatio: CGFloat {
        model.thumbnailAspectMode.frameAspectRatio(
            imageSize: image?.size,
            pixelWidth: item.width,
            pixelHeight: item.height
        )
    }

    private var emptyThumbnailSymbol: String {
        if isCloudOnly {
            return "icloud.and.arrow.down"
        }
        return placeholderIcon
    }

    private var placeholderIcon: String {
        if item.mediaKind == .video, item.availability == .available {
            return "play.rectangle"
        }
        switch item.availability {
        case .available: return "photo"
        case .missing: return "questionmark.folder"
        case .unreadable: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        case .recycled: return "trash"
        }
    }
}

enum VideoDurationText {
    static func format(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
        }
        return String(format: "%lld:%02lld", minutes, seconds)
    }
}

private struct AssetThumbnailLoadID: Hashable {
    let assetID: UUID
    let usesDownloadedCloudPreview: Bool
    let cacheVersion: Int
}

enum LibraryGridThumbnailImageFactory {
    static func image(from data: Data) -> NSImage? {
        guard !data.isEmpty else { return nil }
        if let image = NSImage(data: data) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct InspectorPreview: View {
    let assetID: UUID
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .scaledToFit()
            } else {
                cloudPreviewControls
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: assetID) {
            image = nil
            guard let data = await model.previewData(assetID: assetID) else { return }
            image = NSImage(data: data)
        }
    }

    private var displayedImage: NSImage? {
        if case let .downloaded(downloadedAssetID, data) = model.cloudPreviewState,
           downloadedAssetID == assetID
        {
            return NSImage(data: data)
        }
        return image
    }

    @ViewBuilder
    private var cloudPreviewControls: some View {
        switch model.cloudPreviewState {
        case let .available(cloudAssetID) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("此照片仅存储在 iCloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("从 iCloud 获取预览") {
                    model.downloadCloudPreview(assetID: assetID)
                }
                .buttonStyle(.borderedProminent)
                .persistentHelp("从 iCloud 下载这张照片的临时预览，供本次查看使用。")
            }
        case let .downloading(cloudAssetID, progress) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
                Text("正在从 iCloud 获取预览 · \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消") {
                    model.cancelCloudPreviewDownload(assetID: assetID)
                }
                .persistentHelp("停止下载这张照片的 iCloud 预览。")
            }
        case let .failed(cloudAssetID) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("无法获取 iCloud 预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    model.retryCloudPreviewDownload(assetID: assetID)
                }
                .buttonStyle(.borderedProminent)
                .persistentHelp("重新尝试从 iCloud 获取这张照片的预览。")
            }
        default:
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}
