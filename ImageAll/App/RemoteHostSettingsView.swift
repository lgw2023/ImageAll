import AppKit
import CoreImage.CIFilterBuiltins
import ImageAllRemoteProtocol
import SwiftUI

@MainActor
final class RemoteHostSettingsModel: ObservableObject {
    @Published var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var identityText = "—"
    @Published private(set) var fingerprintText = "—"
    @Published private(set) var offer: RemotePairingOffer?
    @Published private(set) var devices: [RemotePairedDeviceSummary] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var legacyDebugToken: String?

    private let enabledKey = "imageall.remoteHost.enabled"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
#if DEBUG
        legacyDebugToken = RemoteHostProcessHolder.currentAccessToken()
#endif
    }

    func refresh() async {
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

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        statusMessage = "已写入开关。请重新启动 ImageAll 使 Host \(enabled ? "启动" : "停止")。"
    }

    func startPairing() async {
        offer = await RemoteHostProcessHolder.startPairingSession()
        if offer == nil {
            statusMessage = "Host 未运行。请先打开开关并重启应用。"
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
}

struct RemoteHostSettingsView: View {
    @StateObject private var model = RemoteHostSettingsModel()

    var body: some View {
        Form {
            Section("移动辅助 Host") {
                Toggle(
                    "启用局域网 Host",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                LabeledContent("运行状态", value: model.isRunning ? "运行中" : "未运行")
                LabeledContent("Host ID", value: model.identityText)
                LabeledContent("证书指纹") {
                    Text(model.fingerprintText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
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
        .task { await model.refresh() }
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
