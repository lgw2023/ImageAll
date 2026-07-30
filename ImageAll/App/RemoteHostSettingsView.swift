import AppKit
import CoreImage.CIFilterBuiltins
import ImageAllRemoteProtocol
import SwiftUI

@MainActor
final class RemoteHostSettingsModel: ObservableObject {
    @Published var isEnabled: Bool
    @Published var publicBaseURL: String
    @Published private(set) var isRunning = false
    @Published private(set) var identityText = "—"
    @Published private(set) var fingerprintText = "—"
    @Published private(set) var offer: RemotePairingOffer?
    @Published private(set) var devices: [RemotePairedDeviceSummary] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var legacyDebugToken: String?
    @Published private(set) var isApplyingConfiguration = false

    init() {
        isEnabled = RemoteHostProcessHolder.isEnabled()
        publicBaseURL = UserDefaults.standard.string(
            forKey: RemoteHostProcessHolder.publicBaseURLKey
        ) ?? ""
#if DEBUG
        legacyDebugToken = RemoteHostProcessHolder.currentAccessToken()
#endif
    }

    func refresh() async {
        isEnabled = RemoteHostProcessHolder.isEnabled()
        isRunning = await RemoteHostProcessHolder.isRunning()
        if let identity = await RemoteHostProcessHolder.identitySummary() {
            identityText = identity.hostID.uuidString
            fingerprintText = identity.usesTLS
                ? identity.certificateFingerprintSHA256
                : "（无 TLS，Debug 明文）"
        } else {
            identityText = "—"
            fingerprintText = "—"
        }
        offer = await RemoteHostProcessHolder.currentOffer()
        devices = await RemoteHostProcessHolder.pairedDevices()
#if DEBUG
        legacyDebugToken = RemoteHostProcessHolder.currentAccessToken()
#endif
    }

    func refreshUntilStartupSettles() async {
        await refresh()
        guard isEnabled, !isRunning else { return }

        for _ in 0 ..< 20 {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await refresh()
            if isRunning || !isEnabled {
                return
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        isApplyingConfiguration = true
        statusMessage = enabled ? "正在启动移动 Host…" : "正在停止移动 Host…"
        Task {
            let result = await RemoteHostProcessHolder.setEnabled(enabled)
            await refresh()
            isApplyingConfiguration = false
            statusMessage = lifecycleMessage(
                result,
                running: "移动 Host 已启动，可立即开始配对。",
                stopped: "移动 Host 已停止。"
            )
        }
    }

    func savePublicBaseURL() {
        let trimmed = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(
                forKey: RemoteHostProcessHolder.publicBaseURLKey
            )
            publicBaseURL = ""
            applyStoredConfiguration(
                runningMessage: "已关闭公网入口；Host 已切换为局域网模式。"
            )
            return
        }
        guard let normalized = RemotePublicEndpoint.normalizedHTTPSBaseURL(trimmed) else {
            statusMessage = "公网入口必须是专用域名的根路径 HTTPS URL（标准 443 端口）。"
            return
        }
        UserDefaults.standard.set(
            normalized,
            forKey: RemoteHostProcessHolder.publicBaseURLKey
        )
        publicBaseURL = normalized
        applyStoredConfiguration(
            runningMessage: "公网入口已生效；请生成新的配对二维码。"
        )
    }

    func startPairing() async {
        offer = await RemoteHostProcessHolder.startPairingSession()
        if offer == nil {
            statusMessage = "Host 尚未就绪，请确认“启用移动 Host”已打开后重试。"
        } else {
            statusMessage = "配对会话已开始（约 5 分钟有效）"
        }
        await refresh()
    }

    func cancelPairing() async {
        await RemoteHostProcessHolder.cancelPairingSession()
        offer = nil
        statusMessage = "已取消配对会话"
        await refresh()
    }

    func revoke(_ deviceID: UUID) async {
        await RemoteHostProcessHolder.revoke(deviceID: deviceID)
        statusMessage = "已撤销设备"
        await refresh()
    }

    func copyOfferJSON() {
        guard let offer,
              let data = try? JSONEncoder().encode(offer),
              let text = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "配对载荷已复制到剪贴板"
    }

    var webPairingURL: URL? {
        offer.flatMap(RemoteWebCompanionSession.webPairingURL(for:))
    }

    func copyWebPairingURL() {
        guard let url = webPairingURL else {
            statusMessage = "请先保存公网入口并重新开始配对。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        statusMessage = "网页版配对链接已复制；链接中的一次性令牌不会发送给 Cloudflare。"
    }

    private func applyStoredConfiguration(runningMessage: String) {
        isApplyingConfiguration = true
        statusMessage = "正在应用 Host 设置…"
        Task {
            let result = await RemoteHostProcessHolder.reloadConfiguration()
            await refresh()
            isApplyingConfiguration = false
            statusMessage = lifecycleMessage(
                result,
                running: runningMessage,
                stopped: "设置已保存；移动 Host 当前关闭。"
            )
        }
    }

    private func lifecycleMessage(
        _ result: RemoteHostProcessHolder.LifecycleResult,
        running: String,
        stopped: String
    ) -> String {
        switch result {
        case .running:
            return running
        case .stopped:
            return stopped
        case .waitingForAttachment:
            return "设置已保存；图库服务就绪后会自动启动 Host。"
        case .superseded:
            return "Host 设置已由更新的操作接管。"
        case let .failed(message):
            return "Host 启动失败：\(message)"
        }
    }
}

struct RemoteHostSettingsView: View {
    @StateObject private var model = RemoteHostSettingsModel()

    var body: some View {
        Form {
            Section("移动辅助 Host") {
                Toggle(
                    "启用移动 Host",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                .disabled(model.isApplyingConfiguration)
                LabeledContent("运行状态", value: model.isRunning ? "运行中" : "未运行")
                LabeledContent("Host ID", value: model.identityText)
                LabeledContent("证书指纹") {
                    Text(model.fingerprintText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if model.isRunning,
                   model.offer?.publicBaseURL == nil,
                   model.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Text(
                        """
                        若手机持续连接超时，请打开“系统设置 > 网络 > 防火墙 > 选项”，\
                        关闭“阻止所有传入连接”，并将 ImageAll 设为“允许传入连接”。
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
#if DEBUG
                if let token = model.legacyDebugToken {
                    LabeledContent("Debug Token") {
                        Text(token)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
#endif
            }

            Section("公网 Tunnel") {
                TextField(
                    "https://imageall.example.com",
                    text: $model.publicBaseURL
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存公网入口") {
                        model.savePublicBaseURL()
                    }
                    .disabled(model.isApplyingConfiguration)
                    if let activeURL = model.offer?.publicBaseURL {
                        Text("当前 Host：\(activeURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    """
                    使用 Cloudflare 等出站 Tunnel 时填写专用 HTTPS 根域名。公网模式不需要关闭 \
                    Mac 防火墙；保存后 Host 会立即切换并要求生成新的配对二维码。
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("配对") {
                HStack {
                    Button("开始配对") {
                        Task { await model.startPairing() }
                    }
                    .persistentHelp("生成一次性配对信息，供移动端安全连接这台 Mac。")
                    Button("取消配对", role: .destructive) {
                        Task { await model.cancelPairing() }
                    }
                    .disabled(model.offer == nil)
                    .persistentHelp("作废当前尚未完成的配对信息，移动端将不能再用它连接。")
                    Button("复制配对 JSON") {
                        model.copyOfferJSON()
                    }
                    .disabled(model.offer == nil)
                    .persistentHelp("把当前配对信息复制到剪贴板，便于手动传给移动端。")
                    Button("复制网页版配对链接") {
                        model.copyWebPairingURL()
                    }
                    .disabled(model.webPairingURL == nil)
                    .persistentHelp("复制可在 Safari 中打开的一次性配对链接。")
                }
                if let offer = model.offer {
                    if let image = qrImage(for: offer) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 180, height: 180)
                            .padding(.vertical, 8)
                    }
                    LabeledContent("配对码", value: offer.pairingToken)
                    LabeledContent("端口", value: String(offer.listenPort))
                    LabeledContent("TLS", value: offer.usesTLS ? "是" : "否")
                    if let publicBaseURL = offer.publicBaseURL {
                        LabeledContent("公网入口", value: publicBaseURL)
                        if let webPairingURL = model.webPairingURL {
                            LabeledContent("网页版") {
                                Text(webPairingURL.absoluteString)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Text("尚未开始配对会话")
                        .foregroundStyle(.secondary)
                }
            }

            Section("已配对设备") {
                if model.devices.isEmpty {
                    Text("无")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.deviceName)
                                Text(device.deviceID.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("撤销", role: .destructive) {
                                Task { await model.revoke(device.id) }
                            }
                            .persistentHelp("撤销这台设备的访问授权；设备之后需要重新配对。")
                        }
                    }
                }
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.refreshUntilStartupSettles() }
    }

    private func qrImage(for offer: RemotePairingOffer) -> NSImage? {
        guard let data = try? JSONEncoder().encode(offer),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
