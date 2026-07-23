import Foundation
import SwiftUI

struct TrainingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            slotStrip
            Divider()
            HSplitView {
                runList
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("训练工程")
        .accessibilityLabel("训练工程工作台")
        .task {
            await model.refreshTrainingWorkspace()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                featurePrintTrainingMenu
                Divider()
                Button("个人模型（质心）") {
                    Task { await model.rebuildPersonalModel() }
                }
                .disabled(!model.supportsPersonalModelRebuild)
                Button("超级个人（AdamW）") {
                    Task { await model.rebuildPersonalAdamWModel() }
                }
                .disabled(!model.supportsPersonalAdamWModelRebuild)
            } label: {
                Label("发起训练", systemImage: "play.fill")
            }
            .menuStyle(.borderedButton)
            .disabled(
                model.isRebuildingPersonalModel
                    || model.isRebuildingPersonalAdamWModel
                    || model.isGeneratingPersonalLibrarySuggestions
            )

            Picker(
                "方法筛选",
                selection: Binding(
                    get: { model.trainingRunMethodFilter },
                    set: { method in
                        Task { await model.setTrainingRunMethodFilter(method) }
                    }
                )
            ) {
                Text("全部").tag(Optional<TrainingRunMethod>.none)
                ForEach(TrainingRunMethod.allCases, id: \.self) { method in
                    Text(method.trainingWorkspaceDisplayName)
                        .tag(Optional(method))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                Task { await model.refreshTrainingWorkspace() }
            } label: {
                if model.isRefreshingTrainingWorkspace {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshingTrainingWorkspace)

            Spacer()
            Button("返回图库", systemImage: "photo.on.rectangle") {
                onReturnToLibrary()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var featurePrintTrainingMenu: some View {
        let trainable = model.suggestionOverviews.filter {
            $0.canGenerate || $0.canUpdate
        }
        if trainable.isEmpty {
            Button("特征向量：样本不足") {}
                .disabled(true)
        } else {
            Menu("特征向量近邻") {
                ForEach(trainable) { overview in
                    Button(overview.displayName) {
                        model.requestEnqueueSuggestions(
                            tagID: overview.id,
                            displayName: overview.displayName,
                            mode: overview.canUpdate ? .update : .generate,
                            method: .featureKnn
                        )
                    }
                }
            }
        }
    }

    private var slotStrip: some View {
        HStack(spacing: 10) {
            ForEach(model.trainingSlots) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.method.trainingWorkspaceDisplayName)
                        .font(.subheadline.weight(.semibold))
                    Label(
                        slot.isPublished ? "已就绪" : "尚未训练",
                        systemImage: slot.isPublished
                            ? "checkmark.circle.fill"
                            : "circle.dashed"
                    )
                    .font(.caption)
                    .foregroundStyle(slot.isPublished ? .green : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .accessibilityLabel("三种训练产物状态")
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("训练记录")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            if model.trainingRuns.isEmpty {
                ContentUnavailableView(
                    "暂无训练记录",
                    systemImage: "clock.badge.questionmark",
                    description: Text("从“发起训练”开始；失败和取消的记录也会保留。")
                )
            } else {
                List(
                    model.trainingRuns,
                    selection: Binding(
                        get: { model.selectedTrainingRunID },
                        set: { model.selectTrainingRun($0) }
                    )
                ) { run in
                    TrainingWorkspaceRunRow(run: run)
                        .tag(run.id)
                }
                .listStyle(.sidebar)
                .accessibilityLabel("训练 Run 列表")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let run = model.selectedTrainingRun {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.method.trainingWorkspaceDisplayName)
                                .font(.title2.weight(.semibold))
                            Text(run.id.uuidString.lowercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(run.state.trainingWorkspaceDisplayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                run.state.trainingWorkspaceTint.opacity(0.14),
                                in: Capsule()
                            )
                    }
                    TrainingWorkspaceDetailSection("概览") {
                        LabeledContent("方法", value: run.method.trainingWorkspaceDisplayName)
                        LabeledContent("状态", value: run.state.trainingWorkspaceDisplayName)
                        LabeledContent(
                            "创建时间",
                            value: TrainingWorkspaceDateFormatter.string(run.createdAtMs)
                        )
                        if let startedAtMs = run.startedAtMs {
                            LabeledContent(
                                "开始时间",
                                value: TrainingWorkspaceDateFormatter.string(startedAtMs)
                            )
                        }
                        if let finishedAtMs = run.finishedAtMs {
                            LabeledContent(
                                "结束时间",
                                value: TrainingWorkspaceDateFormatter.string(finishedAtMs)
                            )
                        }
                        if let jobID = run.jobID {
                            LabeledContent("关联任务", value: jobID.uuidString.lowercased())
                        }
                    }
                    TrainingWorkspaceJSONSection(
                        title: "数据",
                        json: run.sampleSummaryJSON,
                        emptyText: "没有样本摘要"
                    )
                    TrainingWorkspaceJSONSection(
                        title: "配置",
                        json: run.configJSON,
                        emptyText: "没有配置摘要"
                    )
                    TrainingWorkspaceMetricsSection(json: run.metricsJSON)
                    TrainingWorkspaceDetailSection("产物") {
                        LabeledContent("类型", value: run.artifactKind ?? "未发布")
                        LabeledContent(
                            "引用",
                            value: TrainingWorkspaceJSONPresentation.safeArtifactReference(
                                run.artifactRef
                            ) ?? (run.artifactRef == nil ? "无" : "已隐藏不安全引用")
                        )
                        if let artifactSHA256 = run.artifactSHA256 {
                            LabeledContent("SHA-256", value: artifactSHA256)
                        }
                        if let manifest = run.sampleManifestSHA256 {
                            LabeledContent("样本清单 SHA-256", value: manifest)
                        }
                    }
                    TrainingWorkspaceJSONSection(
                        title: "结果",
                        json: run.resultSummaryJSON,
                        emptyText: "没有结果摘要"
                    )
                    if let errorCode = run.errorCode {
                        TrainingWorkspaceDetailSection("错误") {
                            LabeledContent("错误码", value: errorCode)
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityLabel("训练 Run 详情")
        } else {
            ContentUnavailableView {
                Label("选择一条训练记录", systemImage: "list.bullet.rectangle")
            } description: {
                Text("这里会展示概览、数据、配置、过程、产物和结果。三种建议可以同时进入待审核队列。")
            }
        }
    }
}

struct TrainingWorkspaceInspectorView: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("训练工程")
                .font(.headline)
            if let run = model.selectedTrainingRun {
                LabeledContent("方法", value: run.method.trainingWorkspaceDisplayName)
                LabeledContent("状态", value: run.state.trainingWorkspaceDisplayName)
                LabeledContent(
                    "创建",
                    value: TrainingWorkspaceDateFormatter.string(run.createdAtMs)
                )
                Text("Run \(run.id.uuidString.lowercased())")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("从工作台选择一条 Run，或发起一次训练。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("样本门槛")
                .font(.subheadline.weight(.semibold))
            Text("特征向量：每标签至少 2 个确认 + 2 个不属于。")
            Text("个人模型与超级个人：每标签至少 2 个确认，不强制负例。")
            Text("训练结果不会覆盖人工标签；三种建议可在 Review 中并行出现。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TrainingWorkspaceRunRow: View {
    let run: TrainingRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(run.method.trainingWorkspaceDisplayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(run.state.trainingWorkspaceDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(run.state.trainingWorkspaceTint)
            }
            Text(TrainingWorkspaceDateFormatter.string(run.createdAtMs))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(run.id.uuidString.lowercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingWorkspaceDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct TrainingWorkspaceJSONSection: View {
    let title: String
    let json: String
    let emptyText: String

    var body: some View {
        TrainingWorkspaceDetailSection(title) {
            Text(TrainingWorkspaceJSONPresentation.pretty(json) ?? emptyText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrainingWorkspaceMetricsSection: View {
    let json: String

    var body: some View {
        TrainingWorkspaceDetailSection("过程") {
            if let summary = TrainingWorkspaceJSONPresentation.metricsSummary(json) {
                Text(summary)
                    .font(.callout)
                Divider()
            }
            Text(TrainingWorkspaceJSONPresentation.prettyMetrics(json) ?? "没有过程指标")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private enum TrainingWorkspaceDateFormatter {
    static func string(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

enum TrainingWorkspaceJSONPresentation {
    private static let sensitiveKeyFragments = [
        "path", "bookmark", "locator", "filename", "original",
    ]

    static func pretty(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let sanitized = sanitize(object, key: nil),
              JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                  withJSONObject: sanitized,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func metricsSummary(_ json: String) -> String? {
        guard let metrics = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any]
        else {
            return nil
        }
        guard let split = metrics["evaluationSplit"] as? String else {
            if json.contains("\"validationLoss\"")
                || json.contains("\"bestValidationLoss\"")
            {
                return "历史指标：评估切分未记录，不能把该 loss 判定为验证损失。"
            }
            return nil
        }
        let trainCount = metrics["trainSampleCount"] as? Int ?? 0
        let validationCount = metrics["validationSampleCount"] as? Int ?? 0
        switch split {
        case "validation":
            return "评估口径：验证集 · 训练样本 \(trainCount) · 验证样本 \(validationCount)"
        case "trainFallback":
            return "评估口径：训练集回退（样本不足，未建立验证集）· 训练样本 \(trainCount)"
        default:
            return "评估口径：\(split)"
        }
    }

    static func prettyMetrics(_ json: String) -> String? {
        pretty(json)?
            .replacingOccurrences(
                of: "\"bestValidationLoss\"",
                with: "\"legacyEvaluationLoss\""
            )
            .replacingOccurrences(
                of: "\"validationLoss\"",
                with: "\"legacyEvaluationLoss\""
            )
    }

    static func safeArtifactReference(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("://"),
              !value.split(separator: "/").contains("..")
        else {
            return nil
        }
        return value
    }

    private static func sanitize(_ value: Any, key: String?) -> Any? {
        if let key {
            let normalized = key.lowercased()
            if sensitiveKeyFragments.contains(where: normalized.contains) {
                return nil
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if let sanitized = sanitize(entry.value, key: entry.key) {
                    result[entry.key] = sanitized
                }
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitize($0, key: nil) }
        }
        return value
    }
}

private extension TrainingRunMethod {
    var trainingWorkspaceDisplayName: String {
        switch self {
        case .featureKnn: "特征向量近邻"
        case .personalCentroid: "个人模型（质心）"
        case .personalAdamW: "超级个人（AdamW）"
        }
    }
}

private extension TrainingRunState {
    var trainingWorkspaceDisplayName: String {
        switch self {
        case .queued: "等待中"
        case .running: "运行中"
        case .succeeded: "成功"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    var trainingWorkspaceTint: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}
