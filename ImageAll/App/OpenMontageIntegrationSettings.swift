import AppKit
import SwiftUI

@MainActor
enum OpenMontageIntegrationControl {
    static func start(provider: any OpenMontageTaskRootProviding) async throws -> String {
        guard OpenMontageConfiguration.enabled() else { throw configurationError("OpenMontage 已停用，请先在设置中启用。") }
        let root = try provider.resolveTaskRoot()
        guard provider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        defer { provider.stopAccessing(root) }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenMontage Helper.app")
        guard FileManager.default.fileExists(atPath: helper.path) else { throw configurationError("App 缺少本地制作组件，请安装完整版本。") }
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImageAll/OpenMontageRuntime", isDirectory: true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("integration-disabled.json"))
        let token = UUID().uuidString
        let config = try OpenMontageConfiguration.load()
        let request: [String: String] = ["token": token, "runtime": parent.path, "configuration": config.json,
            "servicesEnabled": UserDefaults.standard.bool(forKey: OpenMontageConfiguration.servicesKey) ? "true" : "false"]
        try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("launcher-request.json"), options: .atomic)
        var url = URLComponents(); url.scheme = "imageall-openmontage"; url.host = "start"
        url.queryItems = [URLQueryItem(name: "taskRoot", value: root.path), URLQueryItem(name: "runtime", value: parent.path), URLQueryItem(name: "token", value: token)]
        let options = NSWorkspace.OpenConfiguration(); options.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: options)
        _ = try await NSWorkspace.shared.open([url.url!], withApplicationAt: helper, configuration: options)
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(1))
            if let data = try? Data(contentsOf: root.appendingPathComponent("launcher-result.json")),
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], report["token"] as? String == token {
                if !OpenMontageConfiguration.enabled() {
                    try stop(root: root)
                    throw configurationError("OpenMontage 已停用，启动已取消。")
                }
                if report["success"] as? Bool == false { throw configurationError(report["message"] as? String ?? "启动失败") }
                let capability = await OpenMontageTaskDirectoryInspector(rootProvider: provider).capability()
                if capability.state == .ready { return report["message"] as? String ?? "本地制作已启动并连接" }
                if capability.state == .dependenciesUnavailable { throw configurationError(capability.detail) }
            }
        }
        throw configurationError("启动超时，请查看任务目录中的 launcher.log。")
    }
    static func stop(provider: any OpenMontageTaskRootProviding) throws {
        let root = try provider.resolveTaskRoot()
        guard provider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
        defer { provider.stopAccessing(root) }
        try stop(root: root)
    }
    static func stop(root: URL) throws {
        let directory = root.appendingPathComponent("executor")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let request = ["protocolVersion": "1.1", "requestID": UUID().uuidString, "mode": "finish-current",
                       "requestedAt": ISO8601DateFormatter().string(from: Date()), "activeTaskPolicy": "finish the active task before exit"]
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("stop-request.json"), options: .atomic)
    }
}

@MainActor
final class OpenMontagePreferencesModel: ObservableObject {
    @Published var config = OpenMontageConfiguration()
    @Published var environment: [String: String] = [:]
    @Published var servicesEnabled = false
    @Published var message = ""
    @Published var busy = false
    @Published var advancedJSON = ""
    private(set) var credentialsLoaded = false
    func load() {
        credentialsLoaded = false
        do {
            config = try OpenMontageConfiguration.load()
            environment = try OpenMontageCredentials.load(); credentialsLoaded = true
            servicesEnabled = UserDefaults.standard.bool(forKey: OpenMontageConfiguration.servicesKey)
            advancedJSON = config.json
        } catch { message = error.localizedDescription }
    }
    func save() {
        do {
            guard credentialsLoaded else { throw configurationError("钥匙串读取失败，不能覆盖现有凭据；请重试读取。") }
            try config.validate(); try OpenMontageServiceField.validate(environment)
            let data = try JSONEncoder().encode(config)
            try OpenMontageCredentials.save(environment)
            UserDefaults.standard.set(data, forKey: OpenMontageConfiguration.configurationKey)
            UserDefaults.standard.set(servicesEnabled, forKey: OpenMontageConfiguration.servicesKey)
            advancedJSON = config.json
            message = "已保存。下次启动执行器生效；如已运行，请先停止，完成当前任务后再启动。"
        } catch { message = error.localizedDescription }
    }
    func applyJSON() {
        do { let value = try JSONDecoder().decode(OpenMontageConfiguration.self, from: Data(advancedJSON.utf8)); try value.validate(); config = value; save() }
        catch { message = error.localizedDescription }
    }
    func start() async {
        busy = true; message = "正在启动…"; defer { busy = false }
        do { message = try await OpenMontageIntegrationControl.start(provider: UserDefaultsOpenMontageTaskRootStore()) }
        catch { message = error.localizedDescription }
    }
    func stop() {
        do { try OpenMontageIntegrationControl.stop(provider: UserDefaultsOpenMontageTaskRootStore()); message = "已请求停止：当前任务完成后退出，不取消任务、不删除成片。" }
        catch { message = error.localizedDescription }
    }
    func setEnabled(_ value: Bool) {
        if !value {
            let provider = UserDefaultsOpenMontageTaskRootStore()
            if let root = try? provider.resolveTaskRoot(), provider.startAccessing(root) {
                try? Data("disabled".utf8).write(to: root.appendingPathComponent("integration-disabled.json"), options: .atomic)
                provider.stopAccessing(root)
            }
            stop()
            UserDefaults.standard.set(false, forKey: OpenMontageConfiguration.enabledKey)
            message = "已停用：阻止新任务；已请求当前任务完成后退出。" + (message.contains("已请求停止") ? "" : " 停止状态：\(message)")
        } else { UserDefaults.standard.set(true, forKey: OpenMontageConfiguration.enabledKey); message = "已启用，可以启动本地制作。" }
    }
    func clearCredentials() {
        do { try OpenMontageCredentials.clear(); environment = [:]; credentialsLoaded = true; message = "已清除 OpenMontage 凭据。已运行进程内的凭据在进程停止后释放。" }
        catch { message = error.localizedDescription }
    }
}

struct OpenMontageIntegrationSettingsView: View {
    @StateObject private var preferences = OpenMontagePreferencesModel()
    @StateObject private var connection = OpenMontageSettingsModel()
    @AppStorage(OpenMontageConfiguration.enabledKey) private var enabled = true
    @State private var page = "运行"
    @State private var service = "OpenAI / Google / xAI"
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("启用 OpenMontage", isOn: Binding(get: { enabled }, set: { preferences.setEnabled($0); Task { await connection.refresh() } }))
                .accessibilityIdentifier("openMontageEnabled")
            Text("可选制作组件。停用后仍可编辑故事、预览和使用原生 MP4 导出。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("配置", selection: $page) { ForEach(["运行", "模型与服务", "制作默认值"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Form {
                if page == "运行" {
                    Section("本地制作") {
                        Text("当前编排和固定模板不需要 API Key。")
                        LabeledContent("状态", value: enabled ? connection.statusTitle : "已停用")
                        if let root = connection.configuredRootURL { Text(root.path).font(.caption).textSelection(.enabled) }
                        HStack {
                            Button(preferences.busy ? "启动中…" : "启动本地制作") { Task { await preferences.start(); await connection.refresh() } }.disabled(!enabled || preferences.busy)
                                .accessibilityIdentifier("openMontageSettingsStart")
                            Button("停止执行器") { preferences.stop() }.disabled(!enabled || preferences.busy)
                            Button("检查状态") { Task { await connection.refresh() } }
                        }
                        HStack {
                            Button("选择任务目录…") { connection.chooseTaskRoot() }.disabled(!enabled)
                            Button("断开自选目录") {
                                preferences.setEnabled(false)
                                UserDefaultsOpenMontageTaskRootStore().clearTaskRoot()
                                Task { await connection.refresh() }
                                preferences.message += " 已解除自选目录关联；重新启用后使用默认目录，原目录与成片保留。"
                            }.disabled(!enabled)
                        }
                        Text("停止会等待当前任务完成。更改配置后需停止再启动；退出 App 不会中断已提交制作。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if page == "模型与服务" {
                    Section("创作 Agent 的模型信息") {
                        Text("当前自由创作由外部 Agent 编写方案。以下模型信息供 OpenMontage 配置使用，不代表 App 已内置自动多模态创作；本地模板不调用这些模型。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("提供商", text: $preferences.config.llm.provider)
                        TextField("模型 ID（空白使用服务默认值）", text: Binding(get: { preferences.config.llm.model ?? "" }, set: { preferences.config.llm.model = $0.isEmpty ? nil : $0 }))
                        TextField("温度 0–2", value: $preferences.config.llm.temperature, format: .number)
                        TextField("最大输出 tokens", value: $preferences.config.llm.max_tokens, format: .number)
                    }
                    Section("可选服务") {
                        Toggle("向执行器提供服务配置", isOn: $preferences.servicesEnabled)
                        Text("密钥和服务参数仅保存在本机钥匙串，启动时交给本地执行器。不会写入故事包或启动日志。填写凭据不会自动调用服务，也不改变每次任务的本地使用限制。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("服务类别", selection: $service) { ForEach(OpenMontageServiceField.groups.map(\.0), id: \.self) { Text($0) } }
                        TextField("搜索字段", text: $search)
                        ForEach(OpenMontageServiceField.all.filter { $0.group == service && (search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)) }) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(field.id).font(.caption.monospaced())
                                if field.secret { SecureField("可选，留空不提供", text: binding(field.id)).accessibilityIdentifier("openMontageCredential-" + field.id) }
                                else { TextField("可选，留空使用工具默认值", text: binding(field.id)) }
                            }
                        }
                        Text("各服务只需填写自己要用的项。工具专属模型、声音、提示词等属于单次制作参数；本地 GPU 工具需要另装其运行依赖。Google 服务账号填 JSON 文件路径，不要粘贴私钥。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack { Button("保存配置与凭据") { preferences.save() }; Button("重新读取") { preferences.load() }; Button("清除全部服务凭据", role: .destructive) { preferences.clearCredentials() } }
                    }
                } else {
                    Section("制作默认值与高级配置") {
                        Text("包含预算、检查点、输出格式/编码/分辨率/帧率、工作子目录及模型信息。明确的故事和任务参数优先；预算与检查点是供创作流程使用的策略，不是对所有第三方服务的强制计费上限。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $preferences.advancedJSON).font(.system(.body, design: .monospaced)).frame(minHeight: 260)
                        Button("校验并保存默认值") { preferences.applyJSON() }
                    }
                }
            }.formStyle(.grouped)
            if !preferences.message.isEmpty { Text(preferences.message).font(.callout).textSelection(.enabled).accessibilityIdentifier("openMontagePreferencesStatus") }
        }.padding(16).frame(width: 680, height: 580)
        .task { preferences.load(); await connection.refresh() }
    }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { preferences.environment[key] ?? "" }, set: { preferences.environment[key] = $0 }) }
}
