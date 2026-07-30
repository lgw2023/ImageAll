import AppKit
import CoreImage.CIFilterBuiltins
import ImageAllRemoteProtocol
import SwiftUI

@MainActor
final class RemoteHostSettingsModel: ObservableObject {
    @Published var isEnabled: Bool
    @Published var publicBaseURL: String
    @Published var accountUsername = ""
    @Published var accountPassword = ""
    @Published private(set) var isRunning = false
    @Published private(set) var identityText = "—"
    @Published private(set) var fingerprintText = "—"
    @Published private(set) var offer: RemotePairingOffer?
    @Published private(set) var devices: [RemotePairedDeviceSummary] = []
    @Published private(set) var accessAccounts: [RemoteAccessAccountSummary] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var legacyDebugToken: String?
    @Published private(set) var isApplyingConfiguration = false
    @Published private(set) var isSavingAccount = false

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
        accessAccounts = await RemoteHostProcessHolder.accessAccounts()
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

    func saveAccessAccount() async {
        guard !isSavingAccount else { return }
        let username = accountUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasExisting = accessAccounts.contains { $0.username == username }
        isSavingAccount = true
        defer { isSavingAccount = false }
        do {
            _ = try await RemoteHostProcessHolder.upsertAccessAccount(
                username: username,
                password: accountPassword
            )
            accountUsername = ""
            accountPassword = ""
            accessAccounts = await RemoteHostProcessHolder.accessAccounts()
            statusMessage = wasExisting
                ? "已更新网页账号“\(username)”的密码。"
                : "已将网页账号“\(username)”加入访问白名单。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func removeAccessAccount(username: String) async {
        guard !isSavingAccount else { return }
        isSavingAccount = true
        defer { isSavingAccount = false }
        do {
            try await RemoteHostProcessHolder.removeAccessAccount(username: username)
            accessAccounts = await RemoteHostProcessHolder.accessAccounts()
            statusMessage = "已从网页访问白名单移除“\(username)”。"
        } catch {
            statusMessage = error.localizedDescription
        }
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

    var localWebURL: URL {
        RemoteHostProcessHolder.localWebURL
    }

    func openLocalWeb() {
        guard isRunning else {
            statusMessage = "Host 尚未运行，请先启用移动 Host。"
            return
        }
        NSWorkspace.shared.open(localWebURL)
        statusMessage = "已在浏览器打开本机网页版。"
    }

    func copyLocalWebURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localWebURL.absoluteString, forType: .string)
        statusMessage = "本机网页版地址已复制。"
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
        ScrollView {
            VStack(spacing: 16) {
                hostOverviewCard

                if let statusMessage = model.statusMessage {
                    statusBanner(statusMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                localEndpointCard
                publicEndpointCard
                accessAccountsCard
                pairingCard
                pairedDevicesCard
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .task { await model.refreshUntilStartupSettles() }
    }

    private var hostOverviewCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.13))
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("移动 Host")
                            .font(.title3.weight(.semibold))
                        Text("让 iPhone 和网页端安全访问这台 Mac 上的 ImageAll")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    statusPill

                    Toggle(
                        "启用移动 Host",
                        isOn: Binding(
                            get: { model.isEnabled },
                            set: { model.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.isApplyingConfiguration)
                    .accessibilityLabel("启用移动 Host")
                }

                Divider()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        technicalDetail("Host ID", value: model.identityText)
                        technicalDetail("证书指纹", value: model.fingerprintText)
#if DEBUG
                        if let token = model.legacyDebugToken {
                            technicalDetail("Debug Token", value: token)
                        }
#endif
                    }
                    .padding(.top, 10)
                } label: {
                    Label("Host 身份与证书", systemImage: "checkmark.shield")
                        .font(.callout.weight(.medium))
                }
            }
        }
    }

    private var publicEndpointCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(
                    "公网访问",
                    subtitle: "通过专用 HTTPS 域名，在蜂窝网络或外网连接",
                    systemImage: "globe"
                )

                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(
                        "https://imageall.example.com",
                        text: $model.publicBaseURL
                    )
                    .textFieldStyle(.plain)

                    Button("保存") {
                        model.savePublicBaseURL()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isApplyingConfiguration)
                    .persistentHelp("保存公网入口并重新加载移动 Host。")
                }
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }

                if let activeURL = model.offer?.publicBaseURL {
                    Label {
                        Text("当前生效：\(activeURL)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text("使用 Cloudflare 等出站 Tunnel 时填写专用 HTTPS 根域名。留空则仅允许局域网连接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isRunning,
                   model.offer?.publicBaseURL == nil,
                   model.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Label(
                        "局域网连接超时时，请在系统防火墙中允许 ImageAll 接收入站连接。",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var localEndpointCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(
                    "本机调试",
                    subtitle: "绕过公网链路，直接在这台 Mac 的浏览器访问",
                    systemImage: "desktopcomputer"
                )

                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(model.localWebURL.absoluteString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        model.copyLocalWebURL()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.openLocalWeb()
                    } label: {
                        Label("打开", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isRunning)
                }
                .padding(12)
                .background(
                    .secondary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

                Text("该 HTTP 端口只绑定 127.0.0.1，局域网和公网设备无法访问；登录账号与公网网页版共用同一份白名单。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairingCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    sectionHeading(
                        "连接新设备",
                        subtitle: model.offer == nil
                            ? "生成约 5 分钟有效的一次性二维码"
                            : "二维码已就绪，使用 ImageAll 移动端扫描",
                        systemImage: "qrcode.viewfinder"
                    )

                    Spacer()

                    if model.offer == nil {
                        Button {
                            Task { await model.startPairing() }
                        } label: {
                            Label("开始配对", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isRunning)
                        .persistentHelp("生成一次性配对信息，供移动端安全连接这台 Mac。")
                    } else {
                        Button("取消配对", role: .destructive) {
                            Task { await model.cancelPairing() }
                        }
                        .buttonStyle(.bordered)
                        .persistentHelp("作废当前尚未完成的配对信息。")
                    }
                }

                if let offer = model.offer {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 22) {
                            pairingQRCode(offer)
                            pairingDetails(offer)
                        }

                        VStack(alignment: .leading, spacing: 18) {
                            pairingQRCode(offer)
                            pairingDetails(offer)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: model.isRunning ? "iphone.gen3" : "power")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isRunning ? "尚未开始配对" : "移动 Host 当前未运行")
                                .font(.callout.weight(.medium))
                            Text(model.isRunning ? "点击“开始配对”后，二维码会显示在这里。" : "请先在页面顶部启用移动 Host。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var accessAccountsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeading(
                    "网页访问白名单",
                    subtitle: "账号密码可直接登录网页版，无需配对码或设备 token",
                    systemImage: "person.badge.key"
                )

                VStack(spacing: 10) {
                    TextField("账号名（3–64 个字符）", text: $model.accountUsername)
                        .textContentType(.username)
                        .textFieldStyle(.roundedBorder)

                    SecureField("账号密码（至少 8 个字符）", text: $model.accountPassword)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text("输入已有账号名可随时更新密码。密码只保存为加盐派生值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await model.saveAccessAccount() }
                        } label: {
                            if model.isSavingAccount {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("添加或更新", systemImage: "plus")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.isSavingAccount
                                || model.accountUsername
                                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.accountPassword.isEmpty
                        )
                    }
                }
                .padding(14)
                .background(
                    .secondary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

                if model.accessAccounts.isEmpty {
                    Label(
                        "尚未添加网页账号；当前仍可使用一次性配对码。",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.accessAccounts.enumerated()), id: \.element.id) {
                        index,
                        account in
                        if index > 0 {
                            Divider()
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.username)
                                    .font(.callout.weight(.medium))
                                Text("可使用账号密码直接访问")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("移除", role: .destructive) {
                                Task {
                                    await model.removeAccessAccount(
                                        username: account.username
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isSavingAccount)
                            .persistentHelp("立即停止此账号访问网页版。")
                        }
                    }
                }
            }
        }
    }

    private var pairedDevicesCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeading(
                    "已配对设备",
                    subtitle: model.devices.isEmpty ? "还没有设备获得访问权限" : "管理可以访问此 Host 的设备",
                    systemImage: "iphone.gen3"
                )

                if model.devices.isEmpty {
                    Text("新设备完成扫码配对后会显示在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 {
                            Divider()
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.deviceName)
                                    .font(.callout.weight(.medium))
                                Text(device.deviceID.uuidString)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Button("撤销", role: .destructive) {
                                Task { await model.revoke(device.id) }
                            }
                            .buttonStyle(.bordered)
                            .persistentHelp("撤销这台设备的访问授权；设备之后需要重新配对。")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.65))
                .frame(width: 7, height: 7)
            Text(model.isApplyingConfiguration ? "正在更新" : (model.isRunning ? "运行中" : "已停止"))
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.08), in: Capsule())
    }

    private func statusBanner(_ message: String) -> some View {
        Label(message, systemImage: model.isApplyingConfiguration ? "arrow.triangle.2.circlepath" : "info.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
            }
    }

    private func pairingQRCode(_ offer: RemotePairingOffer) -> some View {
        Group {
            if let image = qrImage(for: offer) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 176, height: 176)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .accessibilityLabel("移动 Host 配对二维码")
            }
        }
    }

    private func pairingDetails(_ offer: RemotePairingOffer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("等待设备扫描", systemImage: "dot.radiowaves.left.and.right")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)

            pairingValue("配对码", value: offer.pairingToken)

            HStack(spacing: 22) {
                compactValue("端口", value: String(offer.listenPort))
                compactValue("TLS", value: offer.usesTLS ? "已启用" : "未启用")
            }

            if let publicBaseURL = offer.publicBaseURL {
                pairingValue("公网入口", value: publicBaseURL)
            }

            HStack(spacing: 8) {
                Button {
                    model.copyOfferJSON()
                } label: {
                    Label("复制配对信息", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .persistentHelp("把当前配对信息复制到剪贴板，便于手动传给移动端。")

                Button {
                    model.copyWebPairingURL()
                } label: {
                    Label("复制网页链接", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .disabled(model.webPairingURL == nil)
                .persistentHelp("复制可在 Safari 中打开的一次性配对链接。")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.75), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }

    private func sectionHeading(
        _ title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func technicalDetail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func pairingValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func compactValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
        }
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
