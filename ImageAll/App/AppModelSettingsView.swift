import SwiftUI

@MainActor
final class AppModelSettingsModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var state: AppModelActivationState

    private let coordinator: AppModelActivationCoordinator
    private var didStart = false
    private var operationID = 0

    init(coordinator: AppModelActivationCoordinator) {
        self.coordinator = coordinator
        isEnabled = coordinator.initiallyEnabled
        state = coordinator.initiallyEnabled ? .validating : .disabled
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
        case .disabled:
            "已关闭"
        case .validating:
            "正在校验"
        case .ready:
            "模型已就绪"
        case .unavailable:
            "模型不可用"
        }
    }

    var modelText: String {
        if case let .ready(identity) = state {
            return identity.modelID
        }
        return "DINOv2 Small"
    }

    var runtimeText: String {
        "App 内 Core ML（本机）"
    }

    var detailText: String {
        switch state {
        case .disabled:
            "模型不会初始化或运行。"
        case .validating:
            "正在校验模型许可证、版本、清单和完整性。"
        case .ready:
            "模型已在 App 内完成校验并可供本地推理。"
        case let .unavailable(reason):
            switch reason {
            case .artifactMissing:
                "模型文件缺失。浏览和人工标签仍可使用。"
            case .manifestInvalid:
                "模型清单无效。浏览和人工标签仍可使用。"
            case .checksumMismatch:
                "模型完整性校验失败。浏览和人工标签仍可使用。"
            case .artifactInvalid:
                "模型无法初始化。浏览和人工标签仍可使用。"
            }
        }
    }
}

struct AppModelSettingsView: View {
    @ObservedObject var model: AppModelSettingsModel

    var body: some View {
        Form {
            Section("本地模型") {
                Toggle(
                    "启用 DINOv2 Small",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                .accessibilityIdentifier("appModelEnabledToggle")

                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if model.state == .validating {
                            ProgressView().controlSize(.small)
                        }
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
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 480, height: 300)
    }
}
