import AppKit
import SwiftUI

struct LibrarySlimmingClusterPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SlimmingClusterKind
    let memberAssetIDs: [UUID]
    let representativeAssetID: UUID
    let score: Double
    let modelIdentity: SlimmingVectorModelIdentity

    var kindTitle: String {
        switch kind {
        case .byteIdentical: "相同 · 字节"
        case .perceptualDuplicate: "相同 · 感知"
        case .nearDuplicateScene: "相似 · 场景"
        }
    }

    var scoreCaption: String {
        switch kind {
        case .byteIdentical:
            "SHA-256 一致 · \(modelIdentity.revisionCaption)"
        case .perceptualDuplicate:
            String(
                format: "感知相近 · %.0f%% · %@",
                score * 100,
                modelIdentity.revisionCaption
            )
        case .nearDuplicateScene:
            String(format: "DINOv2 %.2f · %@", score, modelIdentity.revisionCaption)
        }
    }

    init(_ cluster: SlimmingCluster) {
        id = cluster.id
        kind = cluster.kind
        memberAssetIDs = cluster.memberAssetIDs
        representativeAssetID = cluster.representativeAssetID
        score = cluster.score
        modelIdentity = cluster.modelIdentity
    }
}

struct LibrarySlimmingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @State private var confirmMoveToRecycle = false
    @State private var confirmPurgeEntryID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("工作台", selection: Binding(
                get: { model.librarySlimmingWorkspaceTab },
                set: { model.selectLibrarySlimmingWorkspaceTab($0) }
            )) {
                Text("分析结果").tag(LibrarySlimmingWorkspaceTab.clusters)
                Text("回收站").tag(LibrarySlimmingWorkspaceTab.recycleBin)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.isAnalyzingLibrarySlimming, let progress = model.librarySlimmingScanProgress {
                progressBanner(progress)
                Divider()
            } else if let message = model.librarySlimmingStatusMessage {
                statusBanner(message)
                Divider()
            }

            if model.librarySlimmingWorkspaceTab == .recycleBin {
                recycleBinList
            } else {
                HSplitView {
                    clusterList
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    clusterDetail
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("图库瘦身")
        .accessibilityLabel("图库瘦身工作台")
        .task(id: model.librarySlimmingWorkspaceTab) {
            if model.librarySlimmingWorkspaceTab == .recycleBin {
                await model.refreshLibrarySlimmingRecycleEntries()
            }
        }
        .confirmationDialog(
            "移入回收站",
            isPresented: $confirmMoveToRecycle,
            titleVisibility: .visible
        ) {
            Button("移入回收站（\(model.selectedLibrarySlimmingMemberIDs.count) 张）", role: .destructive) {
                Task { await model.moveSelectedLibrarySlimmingMembersToRecycle() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选中的文件夹照片将移入应用回收站，默认 30 天后永久删除；期间可恢复。Photos 资产会跳过。")
        }
        .confirmationDialog(
            "立即永久删除",
            isPresented: Binding(
                get: { confirmPurgeEntryID != nil },
                set: { if !$0 { confirmPurgeEntryID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let id = confirmPurgeEntryID {
                    Task { await model.purgeLibrarySlimmingRecycleEntry(id) }
                }
                confirmPurgeEntryID = nil
            }
            Button("取消", role: .cancel) {
                confirmPurgeEntryID = nil
            }
        } message: {
            Text("此操作不可撤销，将删除回收站中的原图文件。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.analyzeLibrarySlimming(mode: .catalog) }
            } label: {
                if model.isAnalyzingLibrarySlimming, model.librarySlimmingAnalyzeMode == .catalog {
                    ProgressView()
                        .controlSize(.small)
                    Text("分析中…")
                } else {
                    Label("分析当前库", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isAnalyzingLibrarySlimming || !model.supportsLibrarySlimming)

            Button {
                Task { await model.analyzeLibrarySlimming(mode: .currentFilter) }
            } label: {
                Label("分析当前筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(
                model.isAnalyzingLibrarySlimming
                    || !model.supportsLibrarySlimming
                    || !model.hasLibrarySlimmingFilterScope
            )
            .help("使用侧栏目的地与图库当前标签/来源/搜索筛选作为分析宇宙")

            if !model.librarySlimmingSeedAssetIDs.isEmpty {
                Button {
                    Task { await model.analyzeLibrarySlimming(mode: .seeds) }
                } label: {
                    Label(
                        "按种子查找 (\(model.librarySlimmingSeedAssetIDs.count))",
                        systemImage: "target"
                    )
                }
                .disabled(model.isAnalyzingLibrarySlimming || !model.supportsLibrarySlimming)
            }

            if model.librarySlimmingPendingCount > 0 {
                Text("待分析 \(model.librarySlimmingPendingCount) 张")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            if model.librarySlimmingAnalyzeMode == .currentFilter
                || model.librarySlimmingAnalyzeMode == .seeds
            {
                Text(model.librarySlimmingFilterScopeSummary)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .lineLimit(2)
                    .help("当前筛选范围")
            }

            Text(modeCaption)
                .foregroundStyle(.tertiary)
                .font(.caption)

            Button("返回图库", systemImage: "photo.on.rectangle") {
                onReturnToLibrary()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var modeCaption: String {
        switch model.librarySlimmingAnalyzeMode {
        case .catalog: "模式：当前库"
        case .currentFilter: "模式：当前筛选"
        case .seeds: "模式：种子检索"
        }
    }

    private func progressBanner(_ progress: LibrarySlimmingScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel(progress.caption)
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private var clusterList: some View {
        Group {
            if model.librarySlimmingClusters.isEmpty {
                if model.hasCompletedLibrarySlimmingScan {
                    ContentUnavailableView {
                        Label("无相似结果", systemImage: "checkmark.circle")
                    } description: {
                        Text("本次分析未发现相同或相似簇。可尝试扩大筛选范围、更换种子，或等待待分析照片补全向量。")
                    }
                } else {
                    ContentUnavailableView {
                        Label("尚未分析", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("可分析当前库、当前筛选，或从图库多选后「在图库瘦身中查找」。缺失向量会显示为待分析。")
                    }
                }
            } else {
                List(selection: Binding(
                    get: { model.selectedLibrarySlimmingClusterID },
                    set: { model.selectLibrarySlimmingCluster($0) }
                )) {
                    Section("簇（相同优先）") {
                        ForEach(model.librarySlimmingClusters) { cluster in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(cluster.kindTitle)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(cluster.memberAssetIDs.count) 张")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                Text(cluster.scoreCaption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(cluster.id))
                            .accessibilityLabel("\(cluster.kindTitle)，\(cluster.memberAssetIDs.count) 张")
                        }
                    }
                }
            }
        }
    }

    private var clusterDetail: some View {
        Group {
            if let cluster = model.selectedLibrarySlimmingCluster {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(cluster.kindTitle)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text(cluster.scoreCaption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Text(
                        "成员 \(cluster.memberAssetIDs.count) · 已选 \(model.selectedLibrarySlimmingMemberIDs.count) · ⌘点击多选对比"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                    if model.canMoveSelectedLibrarySlimmingMembersToRecycle {
                        Button(role: .destructive) {
                            confirmMoveToRecycle = true
                        } label: {
                            Label(
                                "移入回收站 (\(model.selectedLibrarySlimmingMemberIDs.count))",
                                systemImage: "trash"
                            )
                        }
                        .disabled(model.isMutatingLibrarySlimmingRecycle)
                        .padding(.horizontal, 16)
                        .help("确认后将选中资产移入回收站（文件夹走应用 quarantine；Photos 经 PhotoKit 进入系统最近删除）")
                    }

                    if model.librarySlimmingComparisonAssetIDs.count >= 2 {
                        comparisonStrip
                            .padding(.horizontal, 16)
                    }

                    ScrollView {
                        LazyVGrid(
                            columns: LibraryGridLayout.gridItems(
                                containerWidth: 720,
                                density: .standard
                            ),
                            spacing: LibraryGridLayout.spacing
                        ) {
                            ForEach(cluster.memberAssetIDs, id: \.self) { assetID in
                                SlimmingThumbnailCell(
                                    model: model,
                                    assetID: assetID,
                                    isSelected: model.selectedLibrarySlimmingMemberIDs.contains(assetID)
                                )
                                .onTapGesture {
                                    let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                    model.selectLibrarySlimmingMember(
                                        assetID,
                                        additive: flags.contains(.command)
                                    )
                                }
                            }
                        }
                        .padding(LibraryGridLayout.horizontalPadding)
                    }
                }
            } else if model.librarySlimmingClusters.isEmpty, model.hasCompletedLibrarySlimmingScan {
                ContentUnavailableView {
                    Label("无相似结果", systemImage: "checkmark.circle")
                } description: {
                    Text("本次分析未发现相同或相似簇。")
                }
            } else if model.librarySlimmingClusters.isEmpty {
                Color.clear
            } else {
                ContentUnavailableView("选择一个簇", systemImage: "photo.stack")
            }
        }
    }

    private var comparisonStrip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(model.librarySlimmingComparisonAssetIDs, id: \.self) { assetID in
                    SlimmingPreviewCell(model: model, assetID: assetID)
                        .frame(width: 280, height: 220)
                }
            }
        }
        .accessibilityLabel("簇内对比预览")
    }

    private var recycleBinList: some View {
        Group {
            if model.librarySlimmingRecycleEntries.isEmpty {
                ContentUnavailableView {
                    Label("回收站为空", systemImage: "trash")
                } description: {
                    Text("从分析结果中多选照片并移入回收站。默认保留 30 天，可恢复或立即永久删除。")
                }
            } else {
                List(model.librarySlimmingRecycleEntries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        SlimmingThumbnailCell(model: model, assetID: entry.assetID, isSelected: false)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                entry.fileName
                                    ?? entry.originalRelativePath
                                    ?? entry.photosLocalIdentifier
                                    ?? "未命名"
                            )
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            Text(entry.sourceKind == .file ? "文件夹" : "Photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                RecycleCountdownFormatter.text(
                                    purgeAfterMs: entry.purgeAfterMs,
                                    nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        Spacer()
                        VStack(spacing: 8) {
                            Button("恢复") {
                                Task { await model.restoreLibrarySlimmingRecycleEntry(entry.id) }
                            }
                            .disabled(model.isMutatingLibrarySlimmingRecycle)
                            Button("立即删除", role: .destructive) {
                                confirmPurgeEntryID = entry.id
                            }
                            .disabled(model.isMutatingLibrarySlimmingRecycle)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct LibrarySlimmingInspectorView: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("图库瘦身")
                .font(.headline)
            Text("查找相同与相似照片，确认后可将文件夹资产移入回收站（30 天后永久删除）。Photos 删除将在后续版本提供。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.librarySlimmingSeedAssetIDs.isEmpty {
                LabeledContent("种子", value: "\(model.librarySlimmingSeedAssetIDs.count) 张")
            }
            if model.librarySlimmingAnalyzeMode == .currentFilter
                || model.librarySlimmingAnalyzeMode == .seeds
            {
                LabeledContent("筛选", value: model.librarySlimmingFilterScopeSummary)
            }
            LabeledContent("回收站", value: "\(model.librarySlimmingRecycleEntries.count) 项")
            if let cluster = model.selectedLibrarySlimmingCluster {
                Divider()
                LabeledContent("类型", value: cluster.kindTitle)
                LabeledContent("成员", value: "\(cluster.memberAssetIDs.count)")
                LabeledContent("已选对比", value: "\(model.selectedLibrarySlimmingMemberIDs.count)")
                LabeledContent("分数", value: cluster.scoreCaption)
            }
            if model.librarySlimmingPendingCount > 0 {
                Divider()
                Text("有 \(model.librarySlimmingPendingCount) 张照片缺少 Feature Print 或 DINOv2，已标为待分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SlimmingThumbnailCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let assetID: UUID
    var isSelected: Bool = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(minWidth: 80, minHeight: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .task(id: assetID) {
            let data = await model.thumbnailData(assetID: assetID)
            if let data {
                image = LibraryGridThumbnailImageFactory.image(from: data)
            }
        }
    }
}

private struct SlimmingPreviewCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let assetID: UUID
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: assetID) {
            let data = await model.previewData(assetID: assetID)
            if let data {
                image = LibraryGridThumbnailImageFactory.image(from: data)
            }
        }
    }
}
