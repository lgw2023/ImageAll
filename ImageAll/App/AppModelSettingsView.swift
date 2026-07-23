import SwiftUI

@MainActor
final class AppModelSettingsModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var state: AppModelActivationState
    @Published private(set) var suggestionDefaults = SuggestionThresholdDefaults.factory
    @Published private(set) var suggestionOverrides: [SuggestionTagThresholdOverrideRow] = []
    @Published private(set) var suggestionReferences:
        [UUID: [SuggestionScoreThresholdMethod: SuggestionThresholdReference]] = [:]
    @Published private(set) var hasSuggestionThresholdPort = false

    private let coordinator: AppModelActivationCoordinator
    private var suggestionThresholds: (any SuggestionThresholdPort)?
    private var didStart = false
    private var operationID = 0

    init(coordinator: AppModelActivationCoordinator) {
        self.coordinator = coordinator
        isEnabled = coordinator.initiallyEnabled
        state = coordinator.initiallyEnabled ? .validating : .disabled
    }

    func attachSuggestionThresholds(_ port: (any SuggestionThresholdPort)?) {
        suggestionThresholds = port
        hasSuggestionThresholdPort = port != nil
        refreshSuggestionThresholds()
    }

    func refreshSuggestionThresholds() {
        guard let suggestionThresholds else {
            suggestionDefaults = .factory
            suggestionOverrides = []
            suggestionReferences = [:]
            return
        }
        suggestionDefaults = (try? suggestionThresholds.defaults()) ?? .factory
        let rows = (try? suggestionThresholds.listTagOverrides()) ?? []
        suggestionOverrides = rows
        var referencesByTag:
            [UUID: [SuggestionScoreThresholdMethod: SuggestionThresholdReference]] = [:]
        for row in rows {
            var references: [SuggestionScoreThresholdMethod: SuggestionThresholdReference] = [:]
            for method in SuggestionScoreThresholdMethod.allCases {
                if let reference = try? suggestionThresholds.referenceSuggestion(
                    tagID: row.tagID,
                    method: method
                ) {
                    references[method] = reference
                }
            }
            if !references.isEmpty {
                referencesByTag[row.tagID] = references
            }
        }
        suggestionReferences = referencesByTag
    }

    func setSuggestionDefault(method: SuggestionScoreThresholdMethod, minScore: Double) {
        guard let suggestionThresholds, minScore.isFinite else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try suggestionThresholds.setDefault(method: method, minScore: minScore, updatedAtMs: nowMs)
            refreshSuggestionThresholds()
        } catch {}
    }

    func clearSuggestionOverride(tagID: UUID, method: SuggestionScoreThresholdMethod) {
        guard let suggestionThresholds else { return }
        do {
            try suggestionThresholds.clearOverride(tagID: tagID, method: method)
            refreshSuggestionThresholds()
        } catch {}
    }

    func setEnabled(_ isEnabled: Bool) {
        didStart = true
        operationID += 1
        let currentOperationID = operationID
        self.isEnabled = isEnabled
        state = isEnabled ? .validating : .disabled
        Task { [weak self] in
            guard let self else { return }
            let finalState = await self.coordinator.setEnabled(isEnabled)
            guard self.operationID == currentOperationID else { return }
            self.state = finalState
        }
    }

    func setSuggestionOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double
    ) {
        guard let suggestionThresholds, minScore.isFinite else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try suggestionThresholds.setOverride(
                tagID: tagID,
                method: method,
                minScore: minScore,
                updatedAtMs: nowMs
            )
            refreshSuggestionThresholds()
        } catch {}
    }

    func suggestionReference(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) -> SuggestionThresholdReference? {
        suggestionReferences[tagID]?[method]
    }

    func applySuggestionReference(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) {
        guard let reference = suggestionReference(tagID: tagID, method: method) else {
            return
        }
        setSuggestionOverride(
            tagID: tagID,
            method: method,
            minScore: reference.minScore
        )
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        operationID += 1
        let currentOperationID = operationID
        state = isEnabled ? .validating : .disabled
        let finalState = await coordinator.start()
        guard operationID == currentOperationID else { return }
        state = finalState
    }

    var statusText: String {
        switch state {
        case .disabled: "已关闭"
        case .validating: "正在校验"
        case .ready: "模型已就绪"
        case .unavailable: "模型不可用"
        }
    }

    var modelText: String {
        if case let .ready(identity) = state { return identity.modelID }
        return "DINOv2 Small"
    }

    var runtimeText: String { "App 内 Core ML（本机）" }

    var detailText: String {
        switch state {
        case .disabled: "模型不会初始化或运行。"
        case .validating: "正在校验模型许可证、版本、清单和完整性。"
        case .ready: "模型已在 App 内完成校验并可供本地推理。"
        case let .unavailable(reason):
            switch reason {
            case .artifactMissing: "模型文件缺失。浏览和人工标签仍可使用。"
            case .manifestInvalid: "模型清单无效。浏览和人工标签仍可使用。"
            case .checksumMismatch: "模型完整性校验失败。浏览和人工标签仍可使用。"
            case .artifactInvalid: "模型无法初始化。浏览和人工标签仍可使用。"
            }
        }
    }
}

struct AppModelSettingsView: View {
    @ObservedObject var model: AppModelSettingsModel
    @State private var showingOverrides = false

    var body: some View {
        Form {
            Section("本地模型") {
                Toggle(
                    "启用 DINOv2 Small",
                    isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })
                )
                .accessibilityIdentifier("appModelEnabledToggle")
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if model.state == .validating { ProgressView().controlSize(.small) }
                        Text(model.statusText)
                    }
                }
                LabeledContent("模型", value: model.modelText)
                LabeledContent("运行方式", value: model.runtimeText)
                Text(model.detailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasSuggestionThresholdPort {
                Section("建议阈值") {
                    Text("三轨分数含义不同，请分别调节；默认 0 表示只要正分就可进队。分数不可横向比较。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    thresholdStepper(title: "特征向量默认门槛", value: model.suggestionDefaults.featureKnn) {
                        model.setSuggestionDefault(method: .featureKnn, minScore: $0)
                    }
                    thresholdStepper(title: "个人模型默认门槛", value: model.suggestionDefaults.personalCentroid) {
                        model.setSuggestionDefault(method: .personalCentroid, minScore: $0)
                    }
                    thresholdStepper(title: "超级个人模型默认门槛", value: model.suggestionDefaults.personalAdamW) {
                        model.setSuggestionDefault(method: .personalAdamW, minScore: $0)
                    }
                    Button("按标签覆盖…") {
                        model.refreshSuggestionThresholds()
                        showingOverrides = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 480, height: model.hasSuggestionThresholdPort ? 460 : 300)
        .sheet(isPresented: $showingOverrides) { SuggestionThresholdOverridesSheet(model: model) }
        .onAppear { model.refreshSuggestionThresholds() }
    }

    private func thresholdStepper(title: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(String(format: "%.2f", value)).monospacedDigit().frame(minWidth: 48, alignment: .trailing)
                Stepper("", value: Binding(get: { value }, set: { onChange($0) }), step: 0.05).labelsHidden()
            }
        }
    }
}

private struct SuggestionThresholdOverridesSheet: View {
    @ObservedObject var model: AppModelSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredRows: [SuggestionTagThresholdOverrideRow] {
        guard !searchText.isEmpty else { return model.suggestionOverrides }
        return model.suggestionOverrides.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按标签覆盖").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("每个标签、每种方法独立设置；清除后继承方法默认。参考值只来自同轨近期拒绝分数，必须点“采用”才会生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("搜索标签", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if model.suggestionOverrides.isEmpty {
                Text("当前没有可设置的活动标签。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filteredRows.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredRows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.displayName).font(.headline)
                        ForEach(SuggestionScoreThresholdMethod.allCases, id: \.rawValue) { method in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(SuggestionScoreThresholdMethodPresentation.displayName(method))
                                        .frame(width: 88, alignment: .leading)
                                    Text(String(format: "%.2f", row.overrides[method] ?? model.suggestionDefaults[method]))
                                        .monospacedDigit()
                                    Stepper(
                                        "",
                                        value: Binding(
                                            get: {
                                                row.overrides[method]
                                                    ?? model.suggestionDefaults[method]
                                            },
                                            set: {
                                                model.setSuggestionOverride(
                                                    tagID: row.tagID,
                                                    method: method,
                                                    minScore: $0
                                                )
                                            }
                                        ),
                                        step: 0.05
                                    )
                                    .labelsHidden()
                                    if row.overrides[method] != nil {
                                        Button("继承默认") {
                                            model.clearSuggestionOverride(
                                                tagID: row.tagID,
                                                method: method
                                            )
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                                if let reference = model.suggestionReference(
                                    tagID: row.tagID,
                                    method: method
                                ) {
                                    HStack {
                                        Text(
                                            "参考建议："
                                                + String(format: "%.2f", reference.minScore)
                                                + "（最近 "
                                                + String(reference.rejectedSampleCount)
                                                + " 个拒绝分数的第 90 百分位）"
                                        )
                                        .foregroundStyle(.secondary)
                                        Button("采用") {
                                            model.applySuggestionReference(
                                                tagID: row.tagID,
                                                method: method
                                            )
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                } else {
                                    Text("暂无参考建议；至少需要 5 个可追溯的同轨拒绝分数。")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 480)
    }
}
