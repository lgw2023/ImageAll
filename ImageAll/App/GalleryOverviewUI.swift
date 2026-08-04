import Charts
import SwiftUI

struct GalleryOverviewView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var snapshot: GalleryOverviewSnapshot?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var refreshedAt: Date?

    private let photoColor = Color(red: 0.18, green: 0.55, blue: 0.82)
    private let videoColor = Color(red: 0.94, green: 0.49, blue: 0.19)

    var body: some View {
        Group {
            if let snapshot {
                overview(snapshot)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("无法读取图库统计", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("目录库没有被修改。请稍后重试。")
                } actions: {
                    Button("重试") { Task { await refresh() } }
                }
            } else {
                ProgressView("正在汇总图库…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(overviewBackground)
        .task { await refresh() }
        .accessibilityIdentifier("galleryOverview")
    }

    private func overview(_ snapshot: GalleryOverviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero(snapshot)

                if snapshot.totalCount == 0 {
                    ContentUnavailableView {
                        Label("图库还没有内容", systemImage: "photo.stack")
                    } description: {
                        Text("连接来源并完成索引后，这里会显示照片、视频、来源与标签统计。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    headlineMetrics(snapshot)
                    mediaLedger(snapshot)
                    sourceAndAvailability(snapshot)
                    positiveTagPanel(snapshot)
                    timelinePanel(snapshot)
                    methodNote(snapshot)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1_240)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refresh() }
    }

    private func hero(_ snapshot: GalleryOverviewSnapshot) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LIBRARY ATLAS")
                    .font(.caption.weight(.bold).monospaced())
                    .tracking(2.2)
                    .foregroundStyle(photoColor)
                Text("图库总览")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("从规模、精确冗余、来源、时间与正样本标签，看清你的整座图库。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(isLoading ? "正在刷新" : "刷新统计", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .persistentHelp("重新读取 ImageAll 目录库中的聚合统计；不会扫描或修改原照片。")

                if let refreshedAt {
                    Text("更新于 \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            photoColor.opacity(0.14),
                            Color.primary.opacity(0.025),
                            videoColor.opacity(0.09),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private func headlineMetrics(_ snapshot: GalleryOverviewSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            spacing: 12
        ) {
            OverviewMetricCard(
                eyebrow: "当前目录",
                value: snapshot.totalCount,
                caption: "照片与视频总数",
                systemImage: "photo.stack",
                tint: photoColor
            )
            OverviewMetricCard(
                eyebrow: "保守去重后",
                value: snapshot.exactUniqueCount,
                caption: "只扣除绝对相同副本",
                systemImage: "checkmark.seal",
                tint: .green
            )
            OverviewMetricCard(
                eyebrow: "确认冗余",
                value: snapshot.exactRedundantCount,
                caption: "视觉相似不计入",
                systemImage: "square.on.square.badge.person.crop",
                tint: videoColor
            )
            OverviewMetricCard(
                eyebrow: "已有正样本",
                value: snapshot.positiveLabeledAssetCount,
                caption: "\(snapshot.acceptedDecisionCount.formatted()) 条人工接受标签",
                systemImage: "tag.fill",
                tint: .teal
            )
        }
    }

    private func mediaLedger(_ snapshot: GalleryOverviewSnapshot) -> some View {
        let photos = snapshot.summary(for: .image)
        let videos = snapshot.summary(for: .video)
        return OverviewPanel(
            title: "媒体账本",
            subtitle: "原始总量与绝对相同去重后的保守数量",
            systemImage: "rectangle.3.group"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    mediaCard(photos, tint: photoColor)
                    mediaCard(videos, tint: videoColor)
                }
                VStack(spacing: 14) {
                    mediaCard(photos, tint: photoColor)
                    mediaCard(videos, tint: videoColor)
                }
            }
        }
    }

    private func mediaCard(
        _ summary: GalleryOverviewMediaSummary,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    summary.mediaKind == .image ? "照片" : "视频",
                    systemImage: summary.mediaKind.systemImage
                )
                .font(.headline)
                .foregroundStyle(tint)
                Spacer()
                Text(summary.totalCount.formatted())
                    .font(.title2.bold().monospacedDigit())
            }

            HStack(spacing: 22) {
                compactMetric("保守去重后", value: summary.exactUniqueCount)
                compactMetric("确认冗余", value: summary.exactRedundantCount)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("精确摘要覆盖")
                    Spacer()
                    Text("\(summary.exactFingerprintCount.formatted()) / \(summary.totalCount.formatted())")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(summary.exactFingerprintCount),
                    total: Double(max(summary.totalCount, 1))
                )
                .tint(tint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.18))
        }
    }

    private func sourceAndAvailability(_ snapshot: GalleryOverviewSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                sourcePanel(snapshot)
                    .frame(maxWidth: .infinity)
                availabilityPanel(snapshot)
                    .frame(width: 330)
            }
            VStack(spacing: 14) {
                sourcePanel(snapshot)
                availabilityPanel(snapshot)
            }
        }
    }

    private func sourcePanel(_ snapshot: GalleryOverviewSnapshot) -> some View {
        let displayed = Array(snapshot.sources.prefix(8))
        let labels = sourceChartLabels(displayed)
        return OverviewPanel(
            title: "来源构成",
            subtitle: snapshot.sources.count > displayed.count
                ? "按媒体数最多的前 \(displayed.count) 个来源"
                : "每个来源中的照片与视频",
            systemImage: "externaldrive.connected.to.line.below"
        ) {
            if displayed.isEmpty {
                emptyChart("暂无来源数据")
            } else {
                Chart {
                    ForEach(displayed) { source in
                        BarMark(
                            x: .value("媒体数", source.imageCount),
                            y: .value("来源", labels[source.id] ?? source.displayName)
                        )
                        .foregroundStyle(photoColor)
                        BarMark(
                            x: .value("媒体数", source.videoCount),
                            y: .value("来源", labels[source.id] ?? source.displayName)
                        )
                        .foregroundStyle(videoColor)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxisLabel("当前目录媒体数")
                .frame(height: max(220, CGFloat(displayed.count) * 34))
                mediaLegend
            }
        }
    }

    private func availabilityPanel(_ snapshot: GalleryOverviewSnapshot) -> some View {
        OverviewPanel(
            title: "可用状态",
            subtitle: "当前目录能否读取",
            systemImage: "gauge.with.dots.needle.50percent"
        ) {
            if snapshot.availability.isEmpty {
                emptyChart("暂无状态数据")
            } else {
                ZStack {
                    Chart(snapshot.availability) { item in
                        SectorMark(
                            angle: .value("媒体数", item.totalCount),
                            innerRadius: .ratio(0.68),
                            angularInset: 1.5
                        )
                        .foregroundStyle(availabilityColor(item.availability))
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 2) {
                        Text(snapshot.totalCount.formatted())
                            .font(.title2.bold().monospacedDigit())
                        Text("当前媒体")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 190)

                VStack(spacing: 7) {
                    ForEach(snapshot.availability) { item in
                        HStack {
                            Circle()
                                .fill(availabilityColor(item.availability))
                                .frame(width: 8, height: 8)
                            Text(availabilityTitle(item.availability))
                            Spacer()
                            Text(item.totalCount.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func positiveTagPanel(_ snapshot: GalleryOverviewSnapshot) -> some View {
        OverviewPanel(
            title: "正样本标签",
            subtitle: "人工接受次数最多的活跃标签；同一媒体可属于多个标签",
            systemImage: "tag.circle"
        ) {
            if snapshot.positiveTags.isEmpty {
                emptyChart("还没有人工接受的标签")
            } else {
                Chart {
                    ForEach(snapshot.positiveTags) { tag in
                        BarMark(
                            x: .value("正样本数", tag.imageCount),
                            y: .value("标签", tag.displayName)
                        )
                        .foregroundStyle(photoColor)
                        BarMark(
                            x: .value("正样本数", tag.videoCount),
                            y: .value("标签", tag.displayName)
                        )
                        .foregroundStyle(videoColor)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxisLabel("人工接受的媒体数")
                .frame(height: max(230, CGFloat(snapshot.positiveTags.count) * 30))
                mediaLegend
            }
        }
    }

    private func timelinePanel(_ snapshot: GalleryOverviewSnapshot) -> some View {
        let displayed = Array(snapshot.years.suffix(16))
        return OverviewPanel(
            title: "时间分布",
            subtitle: snapshot.years.count > displayed.count
                ? "最近 \(displayed.count) 个有媒体记录的年份"
                : "按拍摄时间优先、修改时间补充",
            systemImage: "calendar"
        ) {
            if displayed.isEmpty {
                emptyChart("没有可用的媒体时间")
            } else {
                Chart {
                    ForEach(displayed) { year in
                        BarMark(
                            x: .value("年份", String(year.year)),
                            y: .value("媒体数", year.imageCount)
                        )
                        .foregroundStyle(photoColor)
                        BarMark(
                            x: .value("年份", String(year.year)),
                            y: .value("媒体数", year.videoCount)
                        )
                        .foregroundStyle(videoColor)
                    }
                }
                .chartLegend(.hidden)
                .chartYAxisLabel("媒体数")
                .frame(height: 240)

                HStack {
                    mediaLegend
                    Spacer()
                    if snapshot.undatedCount > 0 {
                        Label(
                            "另有 \(snapshot.undatedCount.formatted()) 个无日期媒体",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func methodNote(_ snapshot: GalleryOverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("统计口径", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(
                "总量统计当前目录中未进入回收生命周期的媒体。去重只使用已验证原始字节摘要，"
                    + "每组绝对相同内容保留 1 个；未完成摘要、视觉相似和视频代表帧相同均按独立媒体保守计数。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                "当前精确摘要覆盖 \(snapshot.exactFingerprintCount.formatted()) / "
                    + "\(snapshot.totalCount.formatted())。刷新只读取 ImageAll 目录库，不访问原照片。"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var mediaLegend: some View {
        HStack(spacing: 14) {
            legendItem("照片", color: photoColor)
            legendItem("视频", color: videoColor)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 6)
            Text(title)
        }
    }

    private func sourceChartLabels(
        _ sources: [GalleryOverviewSourceSummary]
    ) -> [UUID: String] {
        let totals = Dictionary(grouping: sources, by: \.displayName).mapValues(\.count)
        var seen: [String: Int] = [:]
        var labels: [UUID: String] = [:]
        for source in sources {
            let ordinal = seen[source.displayName, default: 0] + 1
            seen[source.displayName] = ordinal
            labels[source.id] = totals[source.displayName, default: 0] > 1
                ? "\(source.displayName) · \(ordinal)"
                : source.displayName
        }
        return labels
    }

    private func compactMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyChart(_ title: String) -> some View {
        Label(title, systemImage: "chart.bar")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var overviewBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [photoColor.opacity(0.035), .clear, videoColor.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private func availabilityTitle(_ availability: AssetAvailability) -> String {
        switch availability {
        case .available: "可读取"
        case .missing: "暂时缺失"
        case .unreadable: "不可读取"
        case .unsupported: "格式不支持"
        case .recycled: "已回收"
        }
    }

    private func availabilityColor(_ availability: AssetAvailability) -> Color {
        switch availability {
        case .available: .green
        case .missing: .orange
        case .unreadable: .red
        case .unsupported: .gray
        case .recycled: .secondary
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading || snapshot == nil else { return }
        isLoading = true
        loadFailed = false
        do {
            snapshot = try await model.fetchGalleryOverview()
            refreshedAt = Date()
        } catch {
            loadFailed = snapshot == nil
        }
        isLoading = false
    }
}

private struct OverviewMetricCard: View {
    let eyebrow: String
    let value: Int
    let caption: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(value.formatted())
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(tint.opacity(0.16))
        }
    }
}

private struct OverviewPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.075))
        }
    }
}
