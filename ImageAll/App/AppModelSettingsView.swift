import SwiftUI

@MainActor
final class AppModelSettingsModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var state: AppModelActivationState
    @Published private(set) var suggestionDefaults = SuggestionThresholdDefaults.factory
    @Published private(set) var suggestionOverrides: [SuggestionTagThresholdOverrideRow] = []
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
            return
        }
        suggestionDefaults = (try? suggestionThresholds.defaults()) ?? .factory
        suggestionOverrides = (try? suggestionThresholds.listTagOverrides()) ?? []
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
                Stepper("", value: Binding(get: { value }, set: { onChange($0) }), in: -1...2, step: 0.05).labelsHidden()
            }
        }
    }
}

private struct SuggestionThresholdOverridesSheet: View {
    @ObservedObject var model: AppModelSettingsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按标签覆盖").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("空表示继承方法默认；清除后恢复默认。").font(.caption).foregroundStyle(.secondary)
            if model.suggestionOverrides.isEmpty {
                Text("当前没有标签覆盖。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(model.suggestionOverrides) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.displayName).font(.headline)
                        ForEach(SuggestionScoreThresholdMethod.allCases, id: \.rawValue) { method in
                            HStack {
                                Text(SuggestionScoreThresholdMethodPresentation.displayName(method))
                                Spacer()
                                if let value = row.overrides[method] {
                                    Text(String(format: "%.2f", value)).monospacedDigit()
                                    Button("清除") { model.clearSuggestionOverride(tagID: row.tagID, method: method) }
                                        .buttonStyle(.borderless)
                                } else {
                                    Text("继承默认").foregroundStyle(.secondary)
                                }
                            }.font(.caption)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
    }
}
