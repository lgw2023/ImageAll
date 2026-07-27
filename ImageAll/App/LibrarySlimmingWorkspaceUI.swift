import AppKit
import SwiftUI

struct LibrarySlimmingClusterPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SlimmingClusterKind
    let memberAssetIDs: [UUID]
    let representativeAssetID: UUID
    let score: Double
    let scoreVersion: String

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
            "SHA-256 一致"
        case .perceptualDuplicate:
            String(format: "感知相近 · %.0f%%", score * 100)
        case .nearDuplicateScene:
            String(format: "DINOv2 %.2f · %@", score, scoreVersion)
        }
    }

    init(_ cluster: SlimmingCluster) {
        id = cluster.id
        kind = cluster.kind
        memberAssetIDs = cluster.memberAssetIDs
        representativeAssetID = cluster.representativeAssetID
        score = cluster.score
        scoreVersion = cluster.scoreVersion
    }
}

struct LibrarySlimmingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let message = model.librarySlimmingStatusMessage {
                statusBanner(message)
                Divider()
            }
            HSplitView {
                clusterList
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                clusterDetail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("图库瘦身")
        .accessibilityLabel("图库瘦身工作台")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.analyzeLibrarySlimming() }
            } label: {
                if model.isAnalyzingLibrarySlimming {
                    ProgressView()
                        .controlSize(.small)
                    Text("分析中…")
                } else {
                    Label("分析当前库", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isAnalyzingLibrarySlimming || !model.supportsLibrarySlimming)

            if model.librarySlimmingPendingCount > 0 {
                Text("待分析 \(model.librarySlimmingPendingCount) 张")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            Text("只读浏览 · 回收站即将推出")
                .foregroundStyle(.tertiary)
                .font(.caption)

            Button("返回图库", systemImage: "photo.on.rectangle") {
                onReturnToLibrary()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                ContentUnavailableView {
                    Label("尚未分析", systemImage: "square.stack.3d.up")
                } description: {
                    Text("点击「分析当前库」查找相同与相似照片。缺失向量的照片会显示为待分析，不会伪装成无相似。")
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

                    Text("成员 \(cluster.memberAssetIDs.count) · 只读预览")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    ScrollView {
                        LazyVGrid(
                            columns: LibraryGridLayout.gridItems(
                                containerWidth: 720,
                                density: .standard
                            ),
                            spacing: LibraryGridLayout.spacing
                        ) {
                            ForEach(cluster.memberAssetIDs, id: \.self) { assetID in
                                SlimmingThumbnailCell(model: model, assetID: assetID)
                            }
                        }
                        .padding(LibraryGridLayout.horizontalPadding)
                    }
                }
            } else if model.librarySlimmingClusters.isEmpty {
                Color.clear
            } else {
                ContentUnavailableView("选择一个簇", systemImage: "photo.stack")
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
            Text("查找相同（字节/感知）与相似（场景）照片。本页只读；移入回收站将在后续版本提供。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let cluster = model.selectedLibrarySlimmingCluster {
                Divider()
                LabeledContent("类型", value: cluster.kindTitle)
                LabeledContent("成员", value: "\(cluster.memberAssetIDs.count)")
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
        .task(id: assetID) {
            let data = await model.thumbnailData(assetID: assetID)
            if let data {
                image = LibraryGridThumbnailImageFactory.image(from: data)
            }
        }
    }
}
