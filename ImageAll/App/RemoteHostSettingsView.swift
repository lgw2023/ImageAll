import AppKit
import AVKit
import CoreImage.CIFilterBuiltins
import ImageIO
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
    @Published private(set) var phoneProjections: [RemoteLocalLibrarySyncStore.Projection] = []
    @Published private(set) var phoneProjectionError: String?
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
        await refreshPhoneProjections()
        accessAccounts = await RemoteHostProcessHolder.accessAccounts()
#if DEBUG
        legacyDebugToken = RemoteHostProcessHolder.currentAccessToken()
#endif
    }

    func refreshPhoneProjections() async {
        do {
            phoneProjections = try await RemoteHostProcessHolder.sharedPhoneProjections()
            phoneProjectionError = nil
        } catch {
            phoneProjectionError = "读取手机分享目录失败：\(error.localizedDescription)"
        }
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

struct RemotePhoneLibraryView: View {
    private struct CollectionChoice: Identifiable {
        let id: UUID
        let name: String
    }

    let projection: RemoteLocalLibrarySyncStore.Projection
    let deviceName: String?
    @StateObject private var archiveModel = PhoneArchiveImportModel()
    @State private var searchText = ""
    @State private var editedProjection: RemoteLocalLibrarySyncStore.Projection?
    @State private var syncEditError: String?
    @State private var sourceLinks: [UUID: PhoneArchiveSourceLink] = [:]
    @State private var archiveLinkError: String?

    private var currentProjection: RemoteLocalLibrarySyncStore.Projection {
        editedProjection ?? projection
    }

    private var knownCollections: [CollectionChoice] {
        let byID = currentProjection.sharedCollectionFacts.reduce(into: [UUID: String]()) {
            result, fact in
            if result[fact.collectionID] == nil {
                result[fact.collectionID] = fact.collectionName
            }
        }
        return byID.map { CollectionChoice(id: $0.key, name: $0.value) }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var visibleAssets: [RemoteLocalLibrarySyncStore.ProjectedAsset] {
        let sorted = currentProjection.assets.sorted {
            let left = $0.asset.createdAtMs ?? Int64.min
            let right = $1.asset.createdAtMs ?? Int64.min
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { projected in
            projected.asset.id.uuidString.localizedCaseInsensitiveContains(searchText)
                || currentProjection.sharedCollectionFacts.contains {
                    $0.assetID == projected.id && $0.included
                        && $0.collectionName.localizedCaseInsensitiveContains(searchText)
                }
                || currentProjection.sharedTagFacts.contains {
                    $0.assetID == projected.id
                        && $0.tagName.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deviceName ?? "未配对设备的历史目录")
                        .font(.title3.weight(.semibold))
                    Text("手机分享目录 · \(currentProjection.assets.count) 项 · 快照 \(currentProjection.snapshotSequence)")
                        .foregroundStyle(.secondary)
                    Text("上次接收：\(receivedTime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新归档状态", systemImage: "arrow.clockwise") {
                    Task { await refreshArchiveLinks() }
                }
                .disabled(archiveModel.isBusy)
            }
            Text("共享标签、ImageAll 集合成员和收藏目标可在 Mac 修改，并等待 iPhone 下次同步；来源 Photos 收藏由 iPhone 另行写回。标有 Mac 已入库归档的项目有独立副本，打开时再次核查。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let syncEditError {
                Text(syncEditError).font(.footnote).foregroundStyle(.red)
            }
            if let archiveLinkError {
                Text(archiveLinkError).font(.footnote).foregroundStyle(.orange)
            }
            if let message = archiveModel.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            TextField("搜索媒体 ID、集合或标签", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if visibleAssets.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "分享目录暂无可见记录" : "没有匹配的项目",
                    systemImage: "photo.on.rectangle.angled"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleAssets) { projected in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: projected.asset.mediaKind == .video ? "video" : "photo")
                        Text(projected.asset.id.uuidString)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(projected.lastVisibleSnapshotSequence == currentProjection.snapshotSequence
                             ? "本次可见" : "当前未观测")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(projected.lastVisibleSnapshotSequence == currentProjection.snapshotSequence
                                ? Color.green : Color.orange)
                    }
                    if let link = sourceLinks[projected.id] {
                        if link.matches(projected.asset) {
                            HStack {
                                Label("Mac 已入库归档 · 打开前复验", systemImage: "archivebox.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("打开 Mac 副本") {
                                    Task { await archiveModel.previewLinkedOriginal(link) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(archiveModel.isBusy)
                            }
                        } else {
                            Text("归档身份与当前手机目录不一致，需先对账；不会自动关联。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if projected.lastVisibleSnapshotSequence < currentProjection.snapshotSequence {
                        Text("保留上次可见记录；可能是权限、离线或来源变化，不代表照片已删除")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let createdAtMs = projected.asset.createdAtMs {
                        Text("拍摄时间：\(Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1_000).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let sharedFavorite = currentProjection.sharedFavoriteFacts.first {
                        $0.assetID == projected.asset.id
                    }
                    Text("共享收藏目标：\(favoriteTarget(sharedFavorite?.target))（版本 \(sharedFavorite?.revision ?? 0)） · 上次目录观测的系统收藏：\(projected.asset.observedFavorite ? "是" : "否")")
                        .font(.caption)
                    Menu("修改共享收藏目标") {
                        Button("收藏") {
                            updateFavorite(
                                assetID: projected.asset.id, target: true,
                                expectedRevision: sharedFavorite?.revision ?? 0
                            )
                        }
                        Button("取消收藏") {
                            updateFavorite(
                                assetID: projected.asset.id, target: false,
                                expectedRevision: sharedFavorite?.revision ?? 0
                            )
                        }
                    }
                    .menuStyle(.borderlessButton)
                    if let sharedFavorite,
                       sharedFavorite.target != projected.asset.observedFavorite {
                        Text("目标与上次来源观测不同；等待 iPhone 确认来源写回与回读")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    let sharedCollections = currentProjection.sharedCollectionFacts.filter {
                        $0.assetID == projected.asset.id && $0.included
                    }
                    if !sharedCollections.isEmpty {
                        Text("共享集合：\(sharedCollections.map(\.collectionName).joined(separator: "、"))")
                            .font(.caption)
                    }
                    if !knownCollections.isEmpty {
                        Menu("修改集合成员") {
                            ForEach(knownCollections) { collection in
                                let current = currentProjection.sharedCollectionFacts.first {
                                    $0.assetID == projected.asset.id
                                        && $0.collectionID == collection.id
                                }
                                Button {
                                    updateCollection(
                                        assetID: projected.asset.id,
                                        collectionID: collection.id,
                                        included: !(current?.included ?? false),
                                        expectedRevision: current?.revision ?? 0
                                    )
                                } label: {
                                    Label(
                                        collection.name,
                                        systemImage: current?.included == true ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    let sharedTags = currentProjection.sharedTagFacts.filter {
                        $0.assetID == projected.asset.id
                    }
                    if !sharedTags.isEmpty {
                        ForEach(sharedTags, id: \.tagID) { fact in
                            HStack {
                                Text("共享标签：\(fact.tagName)（\(decisionName(fact.decision))，版本 \(fact.revision)）")
                                    .font(.caption)
                                Menu("修改") {
                                    Button("接受") { updateTag(fact, decision: .accepted) }
                                    Button("拒绝") { updateTag(fact, decision: .rejected) }
                                    Button("清除") { updateTag(fact, decision: .cleared) }
                                }
                                .menuStyle(.borderlessButton)
                            }
                        }
                    }
                    if Dictionary(uniqueKeysWithValues: sharedTags.map { ($0.tagID, $0.decision) })
                        != Dictionary(uniqueKeysWithValues: projected.asset.tagDecisions.map {
                            ($0.tagID, $0.decision)
                        }) {
                        Text("手机上次目录快照与共享标签不同，等待逐项同步或冲突处理")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 5)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 450)
        .onChange(of: projection.sharedTagFacts) { _, _ in editedProjection = nil }
        .onChange(of: projection.sharedCollectionFacts) { _, _ in editedProjection = nil }
        .onChange(of: projection.sharedFavoriteFacts) { _, _ in editedProjection = nil }
        .onChange(of: projection.snapshotSequence) { _, _ in editedProjection = nil }
        .task(id: "\(projection.installID.uuidString)|\(projection.sourceEpoch.uuidString)|\(projection.snapshotSequence)") {
            await refreshArchiveLinks()
        }
        .sheet(item: $archiveModel.preview, onDismiss: { archiveModel.dismissPreview() }) { preview in
            PhoneArchivePreviewSheet(preview: preview)
        }
        .onDisappear { archiveModel.dismissPreview() }
    }

    private func refreshArchiveLinks() async {
        await archiveModel.refresh()
        guard let importer = PhoneArchiveImportProcessHolder.importer() else {
            sourceLinks = [:]
            archiveLinkError = "图库尚未就绪，暂不能核对 Mac 归档状态。"
            return
        }
        do {
            sourceLinks = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.sourceLinks(
                    sourceInstallID: projection.installID,
                    sourceEpoch: projection.sourceEpoch
                )
            }
            archiveLinkError = nil
        } catch {
            sourceLinks = [:]
            archiveLinkError = "核对 Mac 归档身份失败：\(error.localizedDescription)"
        }
    }

    private func favoriteTarget(_ target: Bool?) -> String {
        guard let target else { return "未指定" }
        return target ? "收藏" : "取消收藏"
    }

    private var receivedTime: String {
        guard let milliseconds = projection.acceptedAtMs else { return "时间未知" }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func decisionName(_ decision: RemoteLocalLibraryDecision) -> String {
        switch decision {
        case .accepted: "接受"
        case .rejected: "拒绝"
        case .cleared: "清除"
        }
    }

    private func updateTag(
        _ fact: RemoteLocalLibrarySyncStore.SharedTagFact,
        decision: RemoteLocalLibraryDecision
    ) {
        Task {
            do {
                editedProjection = try await RemoteHostProcessHolder.setSharedPhoneTagDecision(
                    deviceID: currentProjection.deviceID, assetID: fact.assetID,
                    tagID: fact.tagID, decision: decision,
                    expectedRevision: fact.revision
                )
                syncEditError = nil
            } catch {
                syncEditError = "更新共享标签失败：\(error.localizedDescription)"
            }
        }
    }

    private func updateCollection(
        assetID: UUID, collectionID: UUID,
        included: Bool, expectedRevision: Int64
    ) {
        Task {
            do {
                editedProjection = try await RemoteHostProcessHolder.setSharedPhoneCollectionMembership(
                    deviceID: currentProjection.deviceID, assetID: assetID,
                    collectionID: collectionID, included: included,
                    expectedRevision: expectedRevision
                )
                syncEditError = nil
            } catch {
                syncEditError = "更新共享集合成员失败：\(error.localizedDescription)"
            }
        }
    }

    private func updateFavorite(
        assetID: UUID, target: Bool, expectedRevision: Int64
    ) {
        Task {
            do {
                editedProjection = try await RemoteHostProcessHolder.setSharedPhoneFavoriteTarget(
                    deviceID: currentProjection.deviceID, assetID: assetID,
                    target: target, expectedRevision: expectedRevision
                )
                syncEditError = nil
            } catch {
                syncEditError = "更新共享收藏目标失败：\(error.localizedDescription)"
            }
        }
    }
}

struct RemoteHostSettingsView: View {
    @StateObject private var model = RemoteHostSettingsModel()
    @State private var selectedPhoneProjection: RemoteLocalLibrarySyncStore.Projection?

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
                phoneSharesCard
                phoneArchiveCard
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .task { await model.refreshUntilStartupSettles() }
        .sheet(item: $selectedPhoneProjection) { projection in
            RemotePhoneLibraryView(
                projection: projection,
                deviceName: model.devices.first(where: { $0.deviceID == projection.deviceID })?.deviceName
            )
        }
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

    private var phoneSharesCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionHeading(
                        "来自 iPhone 的分享目录",
                        subtitle: "显示上次手动提交的目录与整理信息；原件仍保留在手机",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    Spacer()
                    Button("刷新") { Task { await model.refreshPhoneProjections() } }
                        .buttonStyle(.bordered)
                }

                if let error = model.phoneProjectionError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if model.phoneProjections.isEmpty {
                    Text("尚未收到手机分享目录。iPhone 需先选择资产并手动提交。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(model.phoneProjections) { projection in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.devices.first(where: {
                                    $0.deviceID == projection.deviceID
                                })?.deviceName ?? "已撤销或离线的 iPhone")
                                    .font(.callout.weight(.medium))
                                Text("保留目录 \(projection.assets.count) 项 · 已选择 \(projection.selectedAssetIDs.count) 项 · 上次提交 \(projectionTime(projection.acceptedAtMs))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("查看目录") { selectedPhoneProjection = projection }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private var phoneArchiveCard: some View {
        settingsCard { PhoneArchiveImportCard() }
    }

    private func projectionTime(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "时间未知" }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
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

struct PhoneArchivePreview: Identifiable {
    let id: UUID
    let title: String
    let url: URL
    let isVideo: Bool
    let facts: PhoneArchiveImportedFacts
}

@MainActor
final class PhoneArchiveImportModel: ObservableObject {
    @Published private(set) var batches: [PhoneArchiveImportedBatch] = []
    @Published private(set) var items: [PhoneArchiveImportedItem] = []
    @Published private(set) var selectedBatchID: UUID?
    @Published private(set) var latestValidationRecord: PhoneArchiveValidationRecord?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var transferTargetPath: String? =
        RemoteHostProcessHolder.migrationTransferTargetURL()?.path
    @Published private(set) var sealedTransfers: [ImageAllMigrationTransferSealedArchive] = []
    @Published private(set) var galleryOriginalURLs: [UUID: URL] = [:]
    @Published var preview: PhoneArchivePreview?
    private var previewScopedParent: URL?
    private var galleryScopedParent: URL?
    private var galleryLoadGeneration = UUID()

    var selectedBatch: PhoneArchiveImportedBatch? {
        batches.first { $0.id == selectedBatchID }
    }

    func refresh() async {
        guard !isBusy else { return }
        guard let importer = PhoneArchiveImportProcessHolder.importer() else {
            message = "图库尚未就绪，请稍后重试。"
            return
        }
        do {
            let loaded = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.importedBatches()
            }
            batches = loaded
            if let selectedBatchID, loaded.contains(where: { $0.id == selectedBatchID }) {
                await select(selectedBatchID)
            } else if let first = loaded.first {
                await select(first.id)
            } else {
                selectedBatchID = nil
                items = []
            }
            await refreshSealedTransfers()
        } catch {
            message = "读取导入记录失败：\(error.localizedDescription)"
        }
    }

    func chooseNetworkReceiveDirectory() async {
        guard !isBusy else { return }
        guard let target = await chooseDirectory(
            title: "选择 iPhone 网络归档接收目录",
            message: "分片暂存与验证后的 Mac 归档都将保存在这里；请选独立且空间充足的目录。"
        ) else { return }
        guard !isProtectedPhotoVolume(target),
              !target.pathComponents.contains(where: { $0.hasSuffix(".photoslibrary") }) else {
            message = "受保护照片目录或 Photos Library 不能作为网络归档接收目标。"
            return
        }
        guard let importer = PhoneArchiveImportProcessHolder.importer() else {
            message = "图库尚未就绪，请稍后重试。"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let access = target.startAccessingSecurityScopedResource()
            defer { if access { target.stopAccessingSecurityScopedResource() } }
            try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.validateTargetDirectory(target)
            }
            let result = try await RemoteHostProcessHolder.configureMigrationTransferTarget(target)
            transferTargetPath = target.path
            message = result == .running
                ? "网络接收已启用；手机连接此 Mac 后可上传本机归档。"
                : "接收目录已保存；Host 尚未运行，请先启动 Mac 远程服务。"
            await refreshSealedTransfers()
        } catch {
            message = "网络接收目录未启用：\(error.localizedDescription)"
        }
    }

    private func refreshSealedTransfers() async {
        guard let target = RemoteHostProcessHolder.migrationTransferTargetURL() else {
            transferTargetPath = nil
            sealedTransfers = []
            return
        }
        transferTargetPath = target.path
        let access = target.startAccessingSecurityScopedResource()
        defer { if access { target.stopAccessingSecurityScopedResource() } }
        do {
            sealedTransfers = try await ImageAllMigrationTransferStore(root: target)
                .sealedArchives()
        } catch {
            sealedTransfers = []
            message = "读取网络接收记录失败：\(error.localizedDescription)"
        }
    }

    func importSealedTransfer(_ transfer: ImageAllMigrationTransferSealedArchive) async {
        guard !isBusy, let importer = PhoneArchiveImportProcessHolder.importer(),
              let target = RemoteHostProcessHolder.migrationTransferTargetURL() else { return }
        isBusy = true
        defer { isBusy = false }
        let access = target.startAccessingSecurityScopedResource()
        defer { if access { target.stopAccessingSecurityScopedResource() } }
        do {
            let receipt = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.importArchive(from: transfer.packageURL, to: target)
            }
            message = "Mac 已复验 \(receipt.itemCount) 项、\(receipt.resourceCount) 个资源并应用现有整理快照；完成回执仍需共享冲突及事实水位验收。"
            isBusy = false
            await refresh()
        } catch {
            message = "接收包入库失败：\(error.localizedDescription)"
        }
    }

    func select(_ id: UUID) async {
        guard !isBusy, let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        dismissGallery()
        selectedBatchID = id
        items = []
        latestValidationRecord = nil
        await loadMore(using: importer)
        do {
            latestValidationRecord = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.latestValidationRecord(migrationID: id)
            }
        } catch {
            message = "读取归档验收历史失败：\(error.localizedDescription)"
        }
    }

    func loadMore() async {
        guard let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        await loadMore(using: importer)
    }

    func refreshVisibleItemsAfterBindingChange() async {
        guard !isBusy, let id = selectedBatchID,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let count = max(items.count, 100)
            let loaded = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.importedItems(migrationID: id, offset: 0, limit: count)
            }
            guard selectedBatchID == id else { return }
            items = loaded
            message = "Mac 资产身份关联已更新；两端整理信息仍独立，后续需按冲突规则收敛。"
        } catch {
            message = "关联已提交，但刷新目录失败：\(error.localizedDescription)"
        }
    }

    private func loadMore(using importer: VerifiedPhoneArchiveImporter) async {
        guard let id = selectedBatchID, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let offset = items.count
        do {
            let next = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.importedItems(migrationID: id, offset: offset)
            }
            guard selectedBatchID == id else { return }
            items.append(contentsOf: next)
        } catch {
            message = "读取归档目录失败：\(error.localizedDescription)"
        }
    }

    func importChosenArchive() async {
        guard !isBusy else { return }
        guard let source = await chooseDirectory(
            title: "选择 iPhone 原件归档包",
            message: "请选择包含 manifest.jsonl 与 resources 的完整归档目录。"
        ) else { return }
        guard let target = await chooseDirectory(
            title: "选择 Mac 归档存放目录",
            message: "ImageAll 会在这里发布经逐资源校验的独立副本。"
        ) else { return }
        guard !isProtectedPhotoVolume(source), !isProtectedPhotoVolume(target) else {
            message = "受保护的 HDD2 真实照片目录不能作为此阶段的归档来源或写入目标。"
            return
        }
        guard let importer = PhoneArchiveImportProcessHolder.importer() else {
            message = "图库尚未就绪，请稍后重试。"
            return
        }
        let sourceScope = source.startAccessingSecurityScopedResource()
        let targetScope = target.startAccessingSecurityScopedResource()
        defer {
            if targetScope { target.stopAccessingSecurityScopedResource() }
            if sourceScope { source.stopAccessingSecurityScopedResource() }
        }
        isBusy = true
        message = "正在校验、复制并入库；请保持目标磁盘连接。"
        do {
            let receipt = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.importArchive(from: source, to: target)
            }
            isBusy = false
            await refresh()
            await select(receipt.migrationID)
            message = receipt.replayed
                ? "归档已存在，副本复验通过：\(receipt.itemCount) 项、\(receipt.resourceCount) 个资源。"
                : "导入完成：\(receipt.itemCount) 项、\(receipt.resourceCount) 个资源已写入 Mac 独立副本。"
        } catch {
            isBusy = false
            message = "归档导入失败：\(error.localizedDescription)"
        }
    }

    func openOriginal(_ item: PhoneArchiveImportedItem) async {
        guard !isBusy, let batch = selectedBatch,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        do {
            let parent = try targetParent(for: batch)
            let accessed = parent.startAccessingSecurityScopedResource()
            defer { if accessed { parent.stopAccessingSecurityScopedResource() } }
            let archive = parent.appendingPathComponent(
                "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
            )
            isBusy = true
            defer { isBusy = false }
            let url = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.verifiedOriginalURL(
                    migrationID: batch.id, mediaID: item.id, archiveRoot: archive
                )
            }
            guard NSWorkspace.shared.open(url) else {
                message = "系统未能打开原件，请确认目标磁盘可用。"
                return
            }
            message = nil
        } catch {
            message = "打开原件前复验失败：\(error.localizedDescription)"
        }
    }

    func previewOriginal(_ item: PhoneArchiveImportedItem) async {
        guard let batch = selectedBatch else { return }
        await previewOriginal(
            migrationID: batch.id, mediaID: item.id,
            title: item.sourceLocalIdentifier, isVideo: item.mediaKind == "video"
        )
    }

    func previewLinkedOriginal(_ link: PhoneArchiveSourceLink) async {
        await previewOriginal(
            migrationID: link.migrationID, mediaID: link.mediaID,
            title: link.sourceLocalIdentifier, isVideo: link.mediaKind == "video"
        )
    }

    private func previewOriginal(
        migrationID: UUID, mediaID: UUID, title: String, isVideo: Bool
    ) async {
        guard !isBusy, let batch = batches.first(where: { $0.id == migrationID }),
              let importer = PhoneArchiveImportProcessHolder.importer() else {
            message = "找不到已入库的 Mac 归档批次，请刷新后重试。"
            return
        }
        dismissPreview()
        isBusy = true
        defer { isBusy = false }
        do {
            let parent = try targetParent(for: batch)
            let accessed = parent.startAccessingSecurityScopedResource()
            do {
                let archive = parent.appendingPathComponent(
                    "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
                )
                let verified = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                    try importer.verifiedPreview(
                        migrationID: batch.id, mediaID: mediaID, archiveRoot: archive
                    )
                }
                previewScopedParent = accessed ? parent : nil
                preview = PhoneArchivePreview(
                    id: mediaID, title: title,
                    url: verified.originalURL, isVideo: isVideo,
                    facts: verified.facts
                )
                message = nil
            } catch {
                if accessed { parent.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch {
            message = "归档预览前复验失败：\(error.localizedDescription)"
        }
    }

    func dismissPreview() {
        preview = nil
        previewScopedParent?.stopAccessingSecurityScopedResource()
        previewScopedParent = nil
    }

    func loadGalleryOriginals() async {
        guard !isBusy, let batch = selectedBatch,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        dismissGallery()
        let generation = galleryLoadGeneration
        isBusy = true
        defer { isBusy = false }
        do {
            let parent = try targetParent(for: batch)
            let accessed = parent.startAccessingSecurityScopedResource()
            do {
                let archive = parent.appendingPathComponent(
                    "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
                )
                let originals = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                    try importer.verifiedGalleryOriginalURLs(
                        migrationID: batch.id, archiveRoot: archive
                    )
                }
                guard selectedBatchID == batch.id,
                      galleryLoadGeneration == generation,
                      !Task.isCancelled else {
                    if accessed { parent.stopAccessingSecurityScopedResource() }
                    return
                }
                galleryScopedParent = accessed ? parent : nil
                galleryOriginalURLs = originals
                message = nil
            } catch {
                if accessed { parent.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch {
            message = "归档缩略图核查失败：\(error.localizedDescription)"
        }
    }

    func dismissGallery() {
        galleryLoadGeneration = UUID()
        galleryOriginalURLs = [:]
        galleryScopedParent?.stopAccessingSecurityScopedResource()
        galleryScopedParent = nil
    }

    func importFactSnapshot() async {
        guard !isBusy, let batch = selectedBatch,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 iPhone 整理信息快照"
        panel.message = "只接受与当前归档批次的来源身份、范围及资产集合一致的快照。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        NSApp.activate(ignoringOtherApps: true)
        let chosen: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: panel.runModal() == .OK ? panel.url : nil)
            }
        }
        guard let chosen else { return }
        guard !isProtectedPhotoVolume(chosen) else {
            message = "受保护的 HDD2 真实照片目录不能作为此阶段的快照来源。"
            return
        }
        let accessed = chosen.startAccessingSecurityScopedResource()
        defer { if accessed { chosen.stopAccessingSecurityScopedResource() } }
        isBusy = true
        do {
            let parent = try targetParent(for: batch)
            let targetAccess = parent.startAccessingSecurityScopedResource()
            defer { if targetAccess { parent.stopAccessingSecurityScopedResource() } }
            let archive = parent.appendingPathComponent(
                "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
            )
            let receipt = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.reconcileFacts(
                    from: chosen, migrationID: batch.id, archiveRoot: archive
                )
            }
            isBusy = false
            await refresh()
            message = receipt.replayed
                ? "此整理信息快照已导入；\(receipt.itemCount) 项事实保持一致。"
                : "已核对 \(receipt.itemCount) 项整理信息；媒体归档完成回执仍需后续独立验收。"
        } catch {
            isBusy = false
            message = "整理信息对账失败：\(error.localizedDescription)"
        }
    }

    func auditSelectedBatch() async {
        guard !isBusy, let batch = selectedBatch,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let parent = try targetParent(for: batch)
            let access = parent.startAccessingSecurityScopedResource()
            defer { if access { parent.stopAccessingSecurityScopedResource() } }
            let archive = parent.appendingPathComponent(
                "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
            )
            let report = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.auditImportedArchive(
                    migrationID: batch.id, archiveRoot: archive
                )
            }
            let checkpoint: String
            if let snapshot = report.factSnapshot, snapshot.syncCheckpoint != nil {
                do {
                    let matches = try await RemoteHostProcessHolder.matchesMigrationCheckpoint(
                        snapshot, manifestSHA256: report.manifestSHA256
                    )
                    checkpoint = matches
                        ? "手机来源复核、归档清单与 Mac 当前分享事实及变化水位一致。"
                        : "候选检查点缺少来源复核证明，或与归档清单、Mac 当前状态不一致；请重新核对并生成检查点。"
                } catch {
                    checkpoint = "Mac 共享状态读取失败，候选检查点尚未通过：\(error.localizedDescription)"
                }
            } else {
                checkpoint = "手机尚未附带验收检查点。"
            }
            message = "Mac 归档逐资源与入库账本核对通过：\(report.itemCount) 项、\(report.resourceCount) 个资源，整理快照序号 \(report.factSnapshotSequence)。\(checkpoint)独立恢复仍待验收。"
        } catch {
            message = "Mac 归档完整性核查未通过：\(error.localizedDescription)"
        }
    }

    func verifySelectedBatchRecovery() async {
        guard !isBusy, let batch = selectedBatch,
              let importer = PhoneArchiveImportProcessHolder.importer(),
              let destination = await chooseDirectory(
                title: "选择空的隔离恢复目录",
                message: "ImageAll 会复制完整归档并新建独立 catalog；目录需要有足够空间且保持为空。"
              ) else { return }
        guard !isProtectedPhotoVolume(destination) else {
            message = "受保护的 HDD2 真实照片目录不能作为恢复验收目标。"
            return
        }
        isBusy = true
        message = "正在从 Mac 归档恢复到独立目录并逐资源对账；请保持目标磁盘连接。"
        defer { isBusy = false }
        do {
            let parent = try targetParent(for: batch)
            let sourceAccess = parent.startAccessingSecurityScopedResource()
            let targetAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if targetAccess { destination.stopAccessingSecurityScopedResource() }
                if sourceAccess { parent.stopAccessingSecurityScopedResource() }
            }
            let archive = parent.appendingPathComponent(
                "ImageAll-Archive-\(batch.id.uuidString.lowercased())", isDirectory: true
            )
            let before = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.auditImportedArchive(migrationID: batch.id, archiveRoot: archive)
            }
            let matchedBefore: Bool
            if let snapshot = before.factSnapshot {
                matchedBefore = (try? await RemoteHostProcessHolder.matchesMigrationCheckpoint(
                    snapshot, manifestSHA256: before.manifestSHA256
                )) ?? false
            } else {
                matchedBefore = false
            }
            let report = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.verifyIndependentRecovery(
                    migrationID: batch.id, archiveRoot: archive,
                    into: destination
                )
            }
            let after = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.auditImportedArchive(migrationID: batch.id, archiveRoot: archive)
            }
            let matchedAfter: Bool
            if let snapshot = after.factSnapshot {
                matchedAfter = (try? await RemoteHostProcessHolder.matchesMigrationCheckpoint(
                    snapshot, manifestSHA256: after.manifestSHA256
                )) ?? false
            } else {
                matchedAfter = false
            }
            if matchedBefore, matchedAfter, before == after {
                let bookmark = try? destination.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil, relativeTo: nil
                )
                do {
                    let record = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                        try importer.recordValidation(
                            migrationID: batch.id, archiveRoot: archive,
                            recovery: report, recoveryParentBookmark: bookmark
                        )
                    }
                    latestValidationRecord = record
                    let stillMatches: Bool
                    if let snapshot = after.factSnapshot {
                        stillMatches = (try? await RemoteHostProcessHolder.matchesMigrationCheckpoint(
                            snapshot, manifestSHA256: after.manifestSHA256
                        )) ?? false
                    } else {
                        stillMatches = false
                    }
                    message = stillMatches
                        ? "独立恢复与当前同步状态均通过，已保存候选验收记录 \(record.id.uuidString)。恢复目录：\(destination.path)。记录需复核，尚非迁移完成回执或第二份备份。"
                        : "候选验收记录已保存，但 Mac 状态随后变化；请复核记录并重新同步。"
                } catch {
                    message = "独立恢复通过，但候选验收记录未保存：\(error.localizedDescription)。恢复目录保留在 \(destination.path)。"
                }
            } else {
                message = "独立恢复通过：\(report.integrity.itemCount) 项及 \(report.integrity.resourceCount) 个资源已在空 catalog 重建；手机检查点缺失或 Mac 状态已变化，未登记候选验收记录。恢复目录：\(destination.path)。"
            }
        } catch {
            message = "独立恢复核查未通过：\(error.localizedDescription)。目标目录可能留有未完成的恢复文件，请检查后另选空目录重试。"
        }
    }

    func auditLatestValidationRecord() async {
        guard !isBusy, let batch = selectedBatch,
              let record = latestValidationRecord,
              record.migrationID == batch.id,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let parent = try targetParent(for: batch)
            let sourceAccess = parent.startAccessingSecurityScopedResource()
            defer { if sourceAccess { parent.stopAccessingSecurityScopedResource() } }
            let recoveryParent: URL
            if let bookmark = record.recoveryParentBookmark {
                var stale = false
                recoveryParent = try URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale
                )
                guard !stale else { throw PhoneArchiveImportError.validationStale }
            } else {
                recoveryParent = URL(fileURLWithPath: record.recoveryCatalogPath)
                    .deletingLastPathComponent()
            }
            guard recoveryParent.standardizedFileURL.path ==
                    URL(fileURLWithPath: record.recoveryCatalogPath)
                        .deletingLastPathComponent().standardizedFileURL.path else {
                throw PhoneArchiveImportError.validationStale
            }
            let recoveryAccess = recoveryParent.startAccessingSecurityScopedResource()
            defer { if recoveryAccess { recoveryParent.stopAccessingSecurityScopedResource() } }
            let report = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.auditValidationRecord(record)
            }
            guard let snapshot = report.factSnapshot,
                  try await RemoteHostProcessHolder.matchesMigrationCheckpoint(
                      snapshot, manifestSHA256: report.manifestSHA256
                  ) else {
                throw PhoneArchiveImportError.validationStale
            }
            message = "候选验收记录 \(record.id.uuidString) 的两份归档、事实与 Mac 当前变化水位仍一致；实体设备与人工审核验收仍未完成。"
        } catch {
            message = "候选验收记录已失效或暂不可复核：\(error.localizedDescription)"
        }
    }

    private func targetParent(for batch: PhoneArchiveImportedBatch) throws -> URL {
        if let bookmark = batch.targetBookmark {
            var stale = false
            return try URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
        }
        return URL(fileURLWithPath: batch.targetParentPath, isDirectory: true)
    }

    private func chooseDirectory(title: String, message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: panel.runModal() == .OK ? panel.url : nil)
            }
        }
    }

    private func isProtectedPhotoVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == "/Volumes/HDD2" || path.hasPrefix("/Volumes/HDD2/")
    }
}

private struct PhoneArchiveImportCard: View {
    @StateObject private var model = PhoneArchiveImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("iPhone 原件归档", systemImage: "externaldrive.badge.plus")
                    .font(.headline)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }
                    .buttonStyle(.bordered)
                Button("导入归档包") { Task { await model.importChosenArchive() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
            Text("手动选择手机导出的完整包和 Mac 保存目录。入库前校验每个资源；这里展示的是 Mac 独立副本，手机原件不会被删除。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("选择网络接收目录") {
                    Task { await model.chooseNetworkReceiveDirectory() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
                Text(model.transferTargetPath ?? "尚未设置网络接收目录")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            ForEach(model.sealedTransfers) { transfer in
                HStack {
                    Text("已校验归档 · \(transfer.id.uuidString)")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("入库并对账") {
                        Task { await model.importSealedTransfer(transfer) }
                    }
                    .disabled(model.isBusy)
                }
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if model.batches.isEmpty {
                Text("尚无已导入的原件归档。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.batches) { batch in
                    Button {
                        Task { await model.select(batch.id) }
                    } label: {
                        HStack {
                            Image(systemName: model.selectedBatchID == batch.id
                                  ? "checkmark.circle.fill" : "archivebox")
                            Text("\(batch.itemCount) 项 · \(batch.resourceCount) 个资源" +
                                 (batch.factSnapshotSequence > 0 ? " · 整理快照已导入" : " · 整理快照待对账"))
                            Spacer()
                            Text(Date(timeIntervalSince1970: TimeInterval(batch.importedAtMs) / 1_000)
                                .formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .disabled(model.isBusy)
                }
            }
            if let batch = model.selectedBatch {
                Divider()
                Text(batch.appleAlbumCoverage == .selectedAssetsOnly
                     ? "来源 Photos 相册仅记录本次所选资产的可访问成员与文件夹路径。"
                     : "此旧归档未记录来源 Photos 相册；0 个来源相册不代表手机没有相册。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(batch.archivePath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("导入整理信息快照") { Task { await model.importFactSnapshot() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    Button("核查 Mac 归档") { Task { await model.auditSelectedBatch() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    Button("验证独立恢复") {
                        Task { await model.verifySelectedBatchRecovery() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
                if let record = model.latestValidationRecord {
                    HStack {
                        Text("候选验收记录 · \(Date(timeIntervalSince1970: TimeInterval(record.createdAtMs) / 1_000).formatted(date: .abbreviated, time: .shortened)) · 需复核")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("复核记录") {
                            Task { await model.auditLatestValidationRecord() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    }
                }
                ForEach(model.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.sourceLocalIdentifier)
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Text("\(item.mediaKind == "video" ? "视频" : "照片") · \(item.resourceCount) 个资源 · \(item.tagCount) 项标签决定 · \(item.collectionCount) 个 ImageAll 集合 · \(item.appleAlbumCount) 个来源相册")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("在 App 中预览") {
                            Task { await model.previewOriginal(item) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                        Button("打开原件") { Task { await model.openOriginal(item) } }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                    }
                    .padding(.vertical, 3)
                }
                if model.items.count < batch.itemCount {
                    Button("加载更多") { Task { await model.loadMore() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                }
            }
        }
        .task { await model.refresh() }
        .sheet(item: $model.preview, onDismiss: { model.dismissPreview() }) { preview in
            PhoneArchivePreviewSheet(preview: preview)
        }
    }
}

struct PhoneArchiveGalleryView: View {
    @StateObject private var model = PhoneArchiveImportModel()
    @State private var bindingItem: PhoneArchiveImportedItem?
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac 已入库的 iPhone 归档")
                        .font(.title2.weight(.semibold))
                    Text("这些媒体存放在 Mac 独立归档中，手机离线后仍可打开。打开前会复验资源与整理信息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task {
                        await model.refresh()
                        await model.loadGalleryOriginals()
                    }
                }
                .disabled(model.isBusy)
            }
            if let message = model.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if model.batches.isEmpty {
                ContentUnavailableView(
                    "尚无已入库的 iPhone 归档",
                    systemImage: "archivebox",
                    description: Text("先在移动 Host 设置中选择归档包或接收目录，完成 Mac 入库后可在这里浏览。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Menu {
                        ForEach(model.batches) { batch in
                            Button {
                                Task {
                                    await model.select(batch.id)
                                    await model.loadGalleryOriginals()
                                }
                            } label: {
                                Text("\(batch.itemCount) 项 · \(batch.id.uuidString)")
                            }
                        }
                    } label: {
                        Label(
                            model.selectedBatch.map { "\($0.itemCount) 项 · \($0.id.uuidString)" } ?? "选择归档",
                            systemImage: "archivebox"
                        )
                    }
                    .disabled(model.isBusy)
                    Spacer()
                    if let batch = model.selectedBatch {
                        Text("\(model.items.count) / \(batch.itemCount) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    Task { await model.previewOriginal(item) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        PhoneArchiveGridThumbnail(
                                            url: model.galleryOriginalURLs[item.id],
                                            isVideo: item.mediaKind == "video"
                                        )
                                        .frame(maxWidth: .infinity, minHeight: 92)
                                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        Text(item.mediaKind == "video" ? "视频" : "照片")
                                            .font(.headline)
                                        if let createdAtMs = item.createdAtMs {
                                            Text(Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1_000)
                                                .formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("\(item.resourceCount) 个资源 · \(item.tagCount) 项标签 · \(item.collectionCount) 个集合")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        if item.assetBindingCount > 0 {
                                            Label("已关联 \(item.assetBindingCount) 项 Mac 资产", systemImage: "link")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(item.sourceLocalIdentifier)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isBusy)
                                .accessibilityLabel("预览归档\(item.mediaKind == "video" ? "视频" : "照片")，\(item.sourceLocalIdentifier)")
                                Button("关联现有 Mac 资产…", systemImage: "link.badge.plus") {
                                    bindingItem = item
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isBusy)
                            }
                        }
                    }
                    if let batch = model.selectedBatch, model.items.count < batch.itemCount {
                        Button("加载更多") { Task { await model.loadMore() } }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    }
                }
            }
        }
        .padding(20)
        .task {
            await model.refresh()
            await model.loadGalleryOriginals()
        }
        .onDisappear {
            model.dismissPreview()
            model.dismissGallery()
        }
        .sheet(item: $model.preview, onDismiss: { model.dismissPreview() }) { preview in
            PhoneArchivePreviewSheet(preview: preview)
        }
        .sheet(item: $bindingItem) { item in
            if let migrationID = model.selectedBatchID {
                PhoneArchiveAssetBindingSheet(migrationID: migrationID, item: item) {
                    Task { await model.refreshVisibleItemsAfterBindingChange() }
                }
            }
        }
    }
}

private struct PhoneArchiveAssetBindingSheet: View {
    let migrationID: UUID
    let item: PhoneArchiveImportedItem
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var candidates: [PhoneArchiveAssetCandidate] = []
    @State private var boundAssets: [PhoneArchiveBoundAsset] = []
    @State private var selected: PhoneArchiveAssetCandidate?
    @State private var revocationTarget: PhoneArchiveBoundAsset?
    @State private var comparisonTarget: PhoneArchiveBoundAsset?
    @State private var showRevokeConfirmation = false
    @State private var message: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联现有 Mac 资产").font(.title2.weight(.semibold))
            Text("iPhone 归档：\(item.sourceLocalIdentifier) · \(item.id.uuidString)")
                .font(.caption).textSelection(.enabled)
            Text("按文件名、来源或资产 ID 搜索，然后核对来源和定位信息。关联只记录身份；不会移动文件或合并标签、相册与收藏。")
                .font(.footnote).foregroundStyle(.secondary)
            if !boundAssets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已确认的 Mac 关联").font(.subheadline.weight(.semibold))
                    ForEach(boundAssets) { asset in
                        HStack {
                            Text("\(asset.displayName) · \(asset.sourceName) · \(asset.id.uuidString)")
                                .font(.caption).textSelection(.enabled)
                            Spacer()
                            Button("对账…") { comparisonTarget = asset }
                                .disabled(isBusy)
                            Button("解除…") {
                                revocationTarget = asset
                                showRevokeConfirmation = true
                            }
                                .disabled(isBusy)
                        }
                    }
                }
            }
            HStack {
                TextField("至少输入两个字符", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await loadCandidates() } }
                Button("搜索") { Task { await loadCandidates() } }
                    .disabled(search.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isBusy)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            List(candidates) { candidate in
                Button {
                    selected = candidate
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(candidate.displayName).font(.headline)
                            Spacer()
                            if selected?.id == candidate.id {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        Text("\(candidate.sourceName) · \(candidate.locatorDescription)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(candidate.id.uuidString)
                            .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        if let createdAtMs = candidate.createdAtMs {
                            Text(Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1_000)
                                .formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let bound = candidate.boundMediaID, bound != item.id {
                            Text("已关联其他媒体").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(candidate.boundMediaID != nil && candidate.boundMediaID != item.id)
            }
            if let selected {
                Text("待确认：\(selected.displayName)（\(selected.sourceName)）→ iPhone 归档 \(item.sourceLocalIdentifier)")
                    .font(.footnote.weight(.medium))
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                Button("确认关联") { Task { await confirm() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || isBusy)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 500)
        .task { await loadBoundAssets() }
        .confirmationDialog(
            "解除这项 Mac 资产的身份关联？",
            isPresented: $showRevokeConfirmation,
            presenting: revocationTarget
        ) { asset in
            Button("解除关联", role: .destructive) {
                Task { await revoke(asset) }
            }
        } message: { asset in
            Text("\(asset.displayName) 将不再与此 iPhone 归档视为同一媒体。文件和两端整理信息不会删除。")
        }
        .sheet(item: $comparisonTarget) { asset in
            PhoneArchiveFactComparisonSheet(
                migrationID: migrationID, mediaID: item.id, asset: asset
            )
        }
    }

    private func loadBoundAssets() async {
        guard let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        do {
            boundAssets = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.boundAssets(migrationID: migrationID, mediaID: item.id)
            }
        } catch {
            message = "读取已关联资产失败：\(error.localizedDescription)"
        }
    }

    private func loadCandidates() async {
        guard !isBusy, let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        let term = search
        isBusy = true
        defer { isBusy = false }
        do {
            candidates = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.assetBindingCandidates(
                    migrationID: migrationID, mediaID: item.id, search: term
                )
            }
            selected = nil
            message = candidates.isEmpty
                ? "前 500 条检索结果中没有同类型的可用 Mac 资产，请缩小关键词。" : nil
        } catch {
            selected = nil
            message = "搜索失败：\(error.localizedDescription)"
        }
    }

    private func confirm() async {
        guard !isBusy, let selected,
              let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.confirmAssetBinding(
                    migrationID: migrationID, mediaID: item.id, candidate: selected
                )
            }
            await loadBoundAssets()
            candidates = []
            self.selected = nil
            message = "关联已记录；整理信息仍需单独对账。"
            onChanged()
        } catch {
            message = "关联失败：\(error.localizedDescription)"
        }
    }

    private func revoke(_ asset: PhoneArchiveBoundAsset) async {
        guard !isBusy, let importer = PhoneArchiveImportProcessHolder.importer() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                try importer.revokeAssetBinding(
                    migrationID: migrationID, mediaID: item.id, assetID: asset.id,
                    confirmationEventID: asset.confirmationEventID
                )
            }
            await loadBoundAssets()
            candidates = []
            selected = nil
            message = "关联已解除并保留审计记录。"
            onChanged()
        } catch {
            message = "解除失败：\(error.localizedDescription)"
        }
    }
}

private struct PhoneArchiveFactComparisonSheet: View {
    let migrationID: UUID
    let mediaID: UUID
    let asset: PhoneArchiveBoundAsset
    @Environment(\.dismiss) private var dismiss
    @State private var comparison: PhoneArchiveBoundFactComparison?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("整理信息对账 · \(asset.displayName)")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("对照的是 Mac catalog 与已入库 iPhone 归档快照；手机后续共享变化、权限和冲突水位仍须单独核验。此页不修改两端事实。")
                .font(.footnote).foregroundStyle(.secondary)
            if let message {
                Text(message).foregroundStyle(.orange)
            } else if let comparison {
                Text(comparison.factSnapshotSequence == 0
                     ? "归档事实版本：初始清单"
                     : "归档事实快照序号：\(comparison.factSnapshotSequence)")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("标签决定").font(.headline)
                        if comparison.tags.isEmpty {
                            Text("归档中没有标签决定").foregroundStyle(.secondary)
                        }
                        ForEach(comparison.tags) { tag in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(tag.phoneTagName) · \(tagStateText(tag.state))")
                                    .font(.subheadline.weight(.medium))
                                Text("手机：\(tag.phoneDecision.rawValue) · Mac：\(tag.macDecision ?? "未设置")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("手机 ID：\(tag.phoneTagID.uuidString) · Mac ID：\(tag.macTagID?.uuidString ?? "未建立")")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            Divider()
                        }
                        if !comparison.macOnlyTags.isEmpty {
                            Text("仅 Mac 有决定的标签").font(.headline)
                            ForEach(comparison.macOnlyTags) { tag in
                                Text("\(tag.tagName)：\(tag.decision)")
                                    .font(.subheadline)
                            }
                        }
                        Text("ImageAll 收藏目标").font(.headline)
                        Text("手机归档：\(favoriteText(comparison.phoneFavoriteTarget)) · Mac：\(favoriteText(comparison.macFavoriteTarget))")
                        Text("iPhone ImageAll 集合").font(.headline)
                        Text(comparison.phoneCollectionNames.isEmpty
                             ? "无已纳入成员" : comparison.phoneCollectionNames.joined(separator: "、"))
                        Text("Mac 主图库尚无对应的 ImageAll 集合成员表；此处仅展示手机归档事实。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("iPhone Photos 来源相册").font(.headline)
                        Text(comparison.phoneAppleAlbumNames.isEmpty
                             ? "无已记录成员" : comparison.phoneAppleAlbumNames.joined(separator: "、"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("正在读取两端整理信息…")
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 540)
        .task {
            guard let importer = PhoneArchiveImportProcessHolder.importer() else {
                message = "图库尚未就绪。"
                return
            }
            do {
                comparison = try await CatalogBlockingExecutor.shared.run(priority: .utility) {
                    try importer.compareBoundAssetFacts(
                        migrationID: migrationID, mediaID: mediaID, assetID: asset.id
                    )
                }
            } catch {
                message = "对账失败：\(error.localizedDescription)"
            }
        }
    }

    private func tagStateText(_ state: PhoneArchiveTagComparisonState) -> String {
        switch state {
        case .same: "一致"
        case .decisionDiffers: "决定不同"
        case .macDecisionMissing: "Mac 未设置决定"
        case .macTagMissing: "Mac 缺少标签身份"
        case .nameAliasRequired: "同名不同 ID，需确认映射"
        case .identityConflict: "标签身份冲突"
        case .macTagArchived: "Mac 标签已归档"
        }
    }

    private func favoriteText(_ value: Bool?) -> String {
        switch value {
        case true: "收藏"
        case false: "不收藏"
        case nil: "未设置"
        }
    }
}

private struct PhoneArchiveGridThumbnail: View {
    let url: URL?
    let isVideo: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 92)
                    .clipped()
            } else {
                Image(systemName: isVideo ? "play.rectangle" : "photo")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let video = isVideo
            let data = await Task.detached(priority: .utility) {
                PhoneArchiveImagePreview.thumbnailData(
                    at: url, maxPixelSize: 320, isVideo: video
                )
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct PhoneArchivePreviewSheet: View {
    let preview: PhoneArchivePreview
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var didLoadImage = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title).font(.headline).lineLimit(1)
                    Text("Mac 独立归档 · 手机无需连接")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("使用系统打开") { NSWorkspace.shared.open(preview.url) }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Group {
                if preview.isVideo {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView("正在准备视频…")
                    }
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else if !didLoadImage {
                    ProgressView("正在准备图片…")
                } else {
                    ContentUnavailableView(
                        "无法在 App 中预览此格式",
                        systemImage: "photo",
                        description: Text("可使用系统打开已校验的 Mac 归档原件。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.94))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("整理信息").font(.subheadline.weight(.semibold))
                    Text("标签决定：\(tagSummary)")
                    Text("ImageAll 集合：\(collectionSummary)")
                    Text("来源 Photos 相册：\(albumSummary)")
                    Text("来源收藏：\(preview.facts.observedFavorite ? "是" : "否") · ImageAll 收藏目标：\(favoriteSummary)")
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            .frame(maxHeight: 115)
        }
        .frame(minWidth: 720, minHeight: 540)
        .task(id: preview.id) {
            if preview.isVideo {
                let playback = AVPlayer(url: preview.url)
                player = playback
                playback.play()
            } else {
                let url = preview.url
                let data = await Task.detached(priority: .utility) {
                    PhoneArchiveImagePreview.thumbnailData(
                        at: url, maxPixelSize: 2_048, isVideo: false
                    )
                }.value
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
                didLoadImage = true
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            image = nil
            didLoadImage = false
        }
    }

    private var tagSummary: String {
        let tags = preview.facts.tagDecisions.map { tag in
            let decision: String
            switch tag.decision {
            case .accepted: decision = "接受"
            case .rejected: decision = "拒绝"
            case .cleared: decision = "清除"
            }
            return "\(tag.tagName)（\(decision)）"
        }
        return tags.isEmpty ? "无" : tags.joined(separator: "、")
    }

    private var collectionSummary: String {
        let names = preview.facts.collections.map(\.collectionName)
        return names.isEmpty ? "无已纳入成员" : names.joined(separator: "、")
    }

    private var albumSummary: String {
        let names = preview.facts.appleAlbums.map { album in
            (album.folderPath.compactMap(\.title) + [album.albumTitle ?? "未命名相册"])
                .joined(separator: "/")
        }
        return names.isEmpty ? "未记录或无可访问成员" : names.joined(separator: "、")
    }

    private var favoriteSummary: String {
        switch preview.facts.favoriteTarget {
        case true: "是"
        case false: "否"
        case nil: "未设置"
        }
    }

}

enum PhoneArchiveImagePreview {
    nonisolated static func thumbnailData(
        at url: URL, maxPixelSize: Int, isVideo: Bool
    ) -> Data? {
        let thumbnail: CGImage
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            guard let frame = try? generator.copyCGImage(
                at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil
            ) else { return nil }
            thumbnail = frame
        } else {
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
            ), let frame = CGImageSourceCreateThumbnailAtIndex(
                source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary
            ) else { return nil }
            thumbnail = frame
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.86,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
