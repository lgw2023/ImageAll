import ImageAllRemoteClient
import ImageAllRemoteProtocol
import SwiftUI
import UIKit
import Vision
import VisionKit

struct RemoteCompanionRootView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var isScannerPresented = false
    @State private var scannerMessage: String?
    @State private var isForgetPairingConfirmationPresented = false
    @State private var selectedTab: RemoteCompanionTab = .library

    var body: some View {
        Group {
            if model.isConnected {
                connectedTabs
            } else {
                NavigationStack {
                    connectionView
                        .navigationTitle("ImageAll Mobile")
                }
            }
        }
        .sheet(isPresented: $isScannerPresented) {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    PairingQRCodeScannerView(
                        onPayload: { payload in
                            isScannerPresented = false
                            Task { await model.pairUsingScannedPayload(payload) }
                        },
                        onError: { message in
                            scannerMessage = message
                        }
                    )
                    if let scannerMessage {
                        Text(scannerMessage)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else {
                        Text("将 Mac 设置中的 ImageAll 配对二维码放入取景框")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("扫描配对二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isScannerPresented = false }
                    }
                }
            }
        }
        .task {
            await model.restoreStoredSessionIfAvailable()
        }
        .confirmationDialog(
            "清除此 iPhone 的配对？",
            isPresented: $isForgetPairingConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清除本机配对凭据", role: .destructive) {
                model.forgetStoredPairing()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后需要重新扫码。Mac 的设备列表会保留撤销记录，可在 Mac 设置中移除。")
        }
    }

    private var connectedTabs: some View {
        VStack(spacing: 0) {
            RemoteConnectionHealthBanner(health: model.connectionHealth)

            TabView(selection: $selectedTab) {
                NavigationStack {
                    RemoteLibraryView(model: model)
                        .navigationTitle("图库")
                        .toolbar { disconnectToolbar }
                }
                .tabItem { Label("图库", systemImage: "photo.on.rectangle.angled") }
                .tag(RemoteCompanionTab.library)

                NavigationStack {
                    RemoteReviewQueueView(model: model)
                        .navigationTitle("审核")
                        .toolbar { disconnectToolbar }
                }
                .tabItem { Label("审核", systemImage: "checklist") }
                .tag(RemoteCompanionTab.review)

                NavigationStack {
                    RemoteTagLibraryView(model: model)
                        .navigationTitle("标签")
                        .toolbar { disconnectToolbar }
                }
                .tabItem { Label("标签", systemImage: "tag") }
                .tag(RemoteCompanionTab.tags)

                NavigationStack {
                    RemoteJobsView(model: model)
                        .navigationTitle("任务")
                        .toolbar { disconnectToolbar }
                }
                .tabItem { Label("任务", systemImage: "bolt.horizontal.circle") }
                .tag(RemoteCompanionTab.jobs)

                NavigationStack {
                    RemoteHostDashboardView(
                        model: model,
                        openSource: { sourceID in
                            model.librarySourceID = sourceID
                            selectedTab = .library
                            Task { await model.reloadAssets(reset: true) }
                        },
                        requestForgetPairing: {
                            isForgetPairingConfirmationPresented = true
                        }
                    )
                    .navigationTitle("Host")
                }
                .tabItem { Label("Host", systemImage: "desktopcomputer") }
                .tag(RemoteCompanionTab.host)
            }
        }
    }

    @ToolbarContentBuilder
    private var disconnectToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("暂时断开") { model.disconnect() }
        }
    }

    private var connectionView: some View {
        Form {
            if let publicBaseURL = model.publicBaseURL {
                Section("公网 Host") {
                    LabeledContent("入口", value: publicBaseURL)
                    Text("当前会话使用公网 HTTPS，不要求 iPhone 与 Mac 位于同一局域网。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("局域网 Host") {
                    if model.discoveredHosts.isEmpty {
                        Text(model.isBrowsing ? "正在搜索…" : "未开始搜索")
                            .foregroundStyle(.secondary)
                        Text("若持续搜索不到，请在下方输入 Mac 的局域网地址后再扫码；127.0.0.1 只代表当前 iPhone。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discoveredHosts) { discovered in
                            Button {
                                model.selectDiscoveredHost(discovered)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(discovered.name)
                                        Text("\(discovered.host):\(discovered.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if discovered.host == model.host, String(discovered.port) == model.port {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if model.hasStoredPairing {
                Section("已配对设备") {
                    Button {
                        Task { await model.reconnectStoredSession() }
                    } label: {
                        if model.isBusy {
                            ProgressView()
                        } else {
                            Label("重新连接已配对 Host", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isBusy)

                    Text("临时断开不会删除配对。重新连接无需刷新或扫描一次性二维码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("清除此 iPhone 的配对", role: .destructive) {
                        isForgetPairingConfirmationPresented = true
                    }
                    .disabled(model.isBusy)
                }
            }

            Section("安全配对") {
                Button {
                    scannerMessage = nil
                    isScannerPresented = true
                } label: {
                    Label("扫描 Mac 配对二维码", systemImage: "qrcode.viewfinder")
                }
                .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)

                if !DataScannerViewController.isSupported || !DataScannerViewController.isAvailable {
                    Text("当前设备不能使用相机扫码，可粘贴配对 JSON。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("手动配对 JSON") {
                    PairingJSONTextEditor(text: $model.pairingOfferJSON)
                        .frame(minHeight: 88)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary)
                        }
                        .accessibilityLabel("配对 JSON")
                    Text("建议优先扫码或从剪贴板读取；输入框不会自动大写或替换引号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("从剪贴板读取") {
                        model.loadPairingOfferFromPasteboard()
                    }
                    Button("清空", role: .destructive) {
                        model.pairingOfferJSON = ""
                    }
                    .disabled(model.pairingOfferJSON.isEmpty)
                    Button("使用配对 JSON") {
                        Task { await model.pairUsingOfferJSON() }
                    }
                    .disabled(
                        model.isBusy
                            || model.pairingOfferJSON
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    )
                }
            }

            Section("手动 Host / 调试连接") {
                TextField("主机", text: $model.host)
                    .textInputAutapitalizationNever()
                    .keyboardType(.URL)
                    .onChange(of: model.host) { _, _ in
                        model.rememberEndpointHint()
                    }
                TextField("端口", text: $model.port)
                    .keyboardType(.numberPad)
                    .onChange(of: model.port) { _, _ in
                        model.rememberEndpointHint()
                    }
                SecureField("Access Token", text: $model.accessToken)
                    .textInputAutapitalizationNever()
                Button {
                    Task { await model.connect() }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("使用 Token 连接")
                    }
                }
                .disabled(model.isBusy)
            }

            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.startBrowsing() }
        .onDisappear {
            if !model.isConnected {
                model.stopBrowsing()
            }
        }
    }
}

private struct RemoteConnectionHealthBanner: View {
    let health: RemoteEventConnectionHealth

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(message)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连接状态：\(message)")
    }

    private var icon: String {
        switch health {
        case .connected:
            "checkmark.circle.fill"
        case .reconnecting:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .hostOffline:
            "wifi.exclamationmark"
        case .stopped:
            "pause.circle"
        }
    }

    private var color: Color {
        switch health {
        case .connected:
            .green
        case .reconnecting:
            .orange
        case .hostOffline, .stopped:
            .red
        }
    }

    private var message: String {
        switch health {
        case .connected:
            "已连接 · 内容会随 Mac Host 实时更新"
        case let .reconnecting(attempt):
            "正在重连（第 \(attempt) 次）· 当前内容可能已过期"
        case .hostOffline:
            "Host 离线 · 当前显示上次同步内容，将自动重试"
        case .stopped:
            "事件通道已停止 · 当前内容不是实时状态"
        }
    }
}

private struct RemoteHostDashboardView: View {
    @ObservedObject var model: RemoteCompanionModel
    let openSource: (UUID) -> Void
    let requestForgetPairing: () -> Void
    @State private var showsCapabilities = false

    var body: some View {
        List {
            Section("Mac Host") {
                if let capabilities = model.capabilities {
                    LabeledContent("版本", value: capabilities.hostAppVersion)
                    LabeledContent("协议", value: "R\(capabilities.protocolVersion)")
                }
                LabeledContent("连接") {
                    Label(transportTitle, systemImage: transportSystemImage)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("入口") {
                    Text(endpointTitle)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if let refreshedAt = model.lastHostStatusRefreshAt {
                    LabeledContent(
                        "Host 状态更新",
                        value: refreshedAt.formatted(date: .omitted, time: .standard)
                    )
                }
                Button {
                    Task { await model.reloadHostStatus() }
                } label: {
                    if model.isRefreshingHostStatus {
                        HStack {
                            ProgressView()
                            Text("正在刷新 Host 状态…")
                        }
                    } else {
                        Label("刷新 Host 状态", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshingHostStatus)
            }

            Section("内容来源") {
                if model.sources.isEmpty {
                    ContentUnavailableView(
                        "没有可用来源",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("请在 Mac ImageAll 中连接文件夹或授权 Photos。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.sources) { source in
                        Button {
                            openSource(source.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: sourceSystemImage(source.kind))
                                    .font(.title3)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.displayName)
                                        .foregroundStyle(.primary)
                                    Text(sourceKindTitle(source.kind))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(sourceStateTitle(source.state))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(sourceStateColor(source.state))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityHint("在图库中只显示这个来源")
                    }
                }
            }

            Section {
                DisclosureGroup(
                    "远程能力（\(model.capabilities?.capabilities.count ?? 0)）",
                    isExpanded: $showsCapabilities
                ) {
                    ForEach(
                        (model.capabilities?.capabilities ?? [])
                            .sorted { $0.rawValue < $1.rawValue },
                        id: \.rawValue
                    ) { capability in
                        Label(remoteCapabilityTitle(capability), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("这里仅展示当前 Host 已声明的窄远程能力；来源连接、Photos 授权和存储维护仍在 Mac 完成。")
            }

            Section("会话") {
                Button("暂时断开", systemImage: "pause.circle") {
                    model.disconnect()
                }
                Button("清除此 iPhone 的配对", systemImage: "trash", role: .destructive) {
                    requestForgetPairing()
                }
            }
        }
        .refreshable { await model.reloadHostStatus() }
        .task { await model.reloadHostStatus() }
        .safeAreaInset(edge: .bottom) {
            RemoteStatusBanner(message: model.statusMessage)
        }
    }

    private var endpointTitle: String {
        model.publicBaseURL ?? "\(model.host):\(model.port)"
    }

    private var transportTitle: String {
        if model.publicBaseURL != nil { return "公网 HTTPS" }
        return model.capabilities?.usesTLS == true ? "局域网 TLS" : "局域网"
    }

    private var transportSystemImage: String {
        model.publicBaseURL != nil ? "lock.shield" : "wifi"
    }
}

private struct RemoteLibraryView: View {
    @ObservedObject var model: RemoteCompanionModel
    @AppStorage("imageall.mobile.library.gridDensity")
    private var gridDensityRawValue = RemoteLibraryGridDensity.standard.rawValue
    @State private var previewTarget: RemotePreviewTarget?
    @State private var isFilterPresented = false
    @State private var isBatchTagWorkbenchPresented = false

    var body: some View {
        VStack(spacing: 0) {
            libraryToolbar

            if model.assets.isEmpty, model.isBusy {
                Spacer()
                ProgressView("正在载入图库…")
                Spacer()
            } else if model.assets.isEmpty {
                ContentUnavailableView(
                    "没有可浏览的项目",
                    systemImage: "photo.on.rectangle",
                    description: Text("选择其他来源，或在 Mac Host 中添加照片。")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: gridDensity.minimumCellWidth,
                                    maximum: gridDensity.maximumCellWidth
                                ),
                                spacing: 8
                            ),
                        ],
                        spacing: 12
                    ) {
                        ForEach(model.assets) { asset in
                            libraryCell(asset)
                                .onAppear {
                                    Task {
                                        await model.loadThumbnailIfNeeded(for: asset)
                                        await model.loadMoreIfNeeded(current: asset)
                                    }
                                }
                        }
                    }
                    .padding(8)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onEnded { scale in
                            if scale > 1.16, let lessDense = gridDensity.lessDense {
                                setGridDensity(lessDense)
                            } else if scale < 0.84, let denser = gridDensity.denser {
                                setGridDensity(denser)
                            }
                        }
                )
                .refreshable { await model.reloadAssets(reset: true) }
            }

            RemoteStatusBanner(
                message: model.statusMessage,
                undo: model.latestUndoID == nil
                    ? nil
                    : { Task { await model.undoLatestTagDecision() } }
            )
            if model.isLibrarySelectionMode {
                librarySelectionBar
            }
        }
        .searchable(text: $model.librarySearchText, prompt: "搜索文件名")
        .task(id: model.librarySearchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.reloadAssets(reset: true)
        }
        .sheet(item: $previewTarget) { target in
            RemoteAssetPreviewView(target: target, model: model)
        }
        .sheet(isPresented: $isFilterPresented) {
            RemoteLibraryFilterSheet(model: model)
        }
        .sheet(isPresented: $isBatchTagWorkbenchPresented) {
            RemoteBatchTagWorkbench(model: model)
        }
    }

    private var libraryToolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("全部来源") {
                    model.librarySourceID = nil
                    Task { await model.reloadAssets(reset: true) }
                }
                ForEach(model.sources) { source in
                    Button(source.displayName) {
                        model.librarySourceID = source.id
                        Task { await model.reloadAssets(reset: true) }
                    }
                }
            } label: {
                Label(librarySourceTitle, systemImage: "externaldrive")
                    .lineLimit(1)
            }

            Menu {
                Button("文件名") { setLibrarySort(.fileNameAscending) }
                Button("最新优先") { setLibrarySort(.newest) }
                Button("最早优先") { setLibrarySort(.oldest) }
            } label: {
                Label(librarySortTitle(model.librarySort), systemImage: "arrow.up.arrow.down")
                    .lineLimit(1)
            }

            Button {
                isFilterPresented = true
            } label: {
                Label(
                    model.activeLibraryFilterCount == 0
                        ? "筛选"
                        : "筛选 \(model.activeLibraryFilterCount)",
                    systemImage: model.activeLibraryFilterCount == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }

            Menu {
                ForEach(RemoteLibraryGridDensity.allCases) { density in
                    Button {
                        setGridDensity(density)
                    } label: {
                        Label(
                            density.title,
                            systemImage: density == gridDensity
                                ? "checkmark"
                                : density.systemImage
                        )
                    }
                }
            } label: {
                Image(systemName: gridDensity.systemImage)
            }
            .accessibilityLabel("图库密度：\(gridDensity.title)")

            Spacer(minLength: 0)

            Button(model.isLibrarySelectionMode ? "完成" : "选择") {
                if model.isLibrarySelectionMode {
                    model.finishLibrarySelection()
                } else {
                    model.beginLibrarySelection()
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var librarySelectionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("已选 \(model.selectedAssetIDs.count) 项")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("全选已载入") { model.selectAllLoadedAssets() }
                Button("反选") { model.invertLoadedAssetSelection() }
                    .accessibilityIdentifier("library-invert-selection")
                Button("清除") { model.clearLibrarySelection() }
                    .disabled(model.selectedAssetIDs.isEmpty)
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(model.tags) { tag in
                        Button {
                            model.libraryActionTagID = tag.id
                        } label: {
                            let aggregate = model.tagSelectionAggregates[tag.id]
                            let counts = aggregate.map {
                                "接受 \($0.acceptedCount) · 拒绝 \($0.rejectedCount) · 未定 \($0.unknownCount)"
                            }
                            Label(
                                counts.map { "\(tag.displayName)（\($0)）" } ?? tag.displayName,
                                systemImage: model.libraryActionTagID == tag.id ? "checkmark" : "tag"
                            )
                        }
                    }
                } label: {
                    Label(libraryActionTagTitle, systemImage: "tag")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(model.tags.isEmpty)

                Button {
                    isBatchTagWorkbenchPresented = true
                } label: {
                    Label("全部标签", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedAssetIDs.isEmpty)
                .accessibilityIdentifier("library-batch-tag-workbench-button")
            }

            RemoteDecisionBar(
                isDisabled: !model.canSendCommands
                    || model.selectedAssetIDs.isEmpty
                    || model.libraryActionTagID == nil,
                accept: { Task { await model.applyTagDecision(.accept) } },
                reject: { Task { await model.applyTagDecision(.reject) } },
                clear: { Task { await model.applyTagDecision(.clear) } }
            )
            .padding(.horizontal, -16)
            .padding(.vertical, -10)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(.bar)
    }

    private func libraryCell(_ asset: RemoteAssetSummary) -> some View {
        let selected = model.selectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Button {
                    if model.isLibrarySelectionMode {
                        model.toggleSelection(asset.id)
                    } else {
                        previewTarget = RemotePreviewTarget(
                            assetID: asset.id,
                            title: asset.fileName,
                            context: .library
                        )
                    }
                } label: {
                    RemoteThumbnailView(
                        data: model.thumbnailDataByAssetID[asset.id],
                        placeholder: asset.fileName ?? String(asset.id.uuidString.prefix(8)),
                        isSelected: selected
                    )
                }
                .buttonStyle(.plain)
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            guard !model.isLibrarySelectionMode else { return }
                            model.beginLibrarySelection()
                            if !model.selectedAssetIDs.contains(asset.id) {
                                model.toggleSelection(asset.id)
                            }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                )
                .accessibilityAction(named: "选择此项目") {
                    model.beginLibrarySelection()
                    if !model.selectedAssetIDs.contains(asset.id) {
                        model.toggleSelection(asset.id)
                    }
                }

                if model.isLibrarySelectionMode {
                    Button {
                        model.toggleSelection(asset.id)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                .white,
                                selected ? Color.accentColor : .black.opacity(0.45)
                            )
                            .shadow(radius: 2)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "取消选择" : "选择")
                }
            }

            Text(asset.fileName ?? "未命名")
                .font(.caption)
                .lineLimit(1)
        }
    }

    private var librarySourceTitle: String {
        guard let id = model.librarySourceID else { return "全部来源" }
        return model.sources.first(where: { $0.id == id })?.displayName ?? "来源"
    }

    private var libraryActionTagTitle: String {
        guard let id = model.libraryActionTagID else { return "选择标签" }
        return model.tags.first(where: { $0.id == id })?.displayName ?? "标签"
    }

    private var gridDensity: RemoteLibraryGridDensity {
        RemoteLibraryGridDensity(rawValue: gridDensityRawValue) ?? .standard
    }

    private func setGridDensity(_ density: RemoteLibraryGridDensity) {
        guard density != gridDensity else { return }
        gridDensityRawValue = density.rawValue
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func setLibrarySort(_ sort: RemoteAssetSort) {
        model.librarySort = sort
        Task { await model.reloadAssets(reset: true) }
    }
}

private struct RemoteBatchTagWorkbench: View {
    @ObservedObject var model: RemoteCompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCreateTagPresented = false
    @State private var newTagName = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.selectedAssetIDs.isEmpty {
                    ContentUnavailableView {
                        Label("没有选中项目", systemImage: "checkmark.circle")
                    } description: {
                        Text("返回图库后选择要连续整理的项目。")
                    } actions: {
                        Button("返回图库") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        selectionSection

                        if model.tags.isEmpty {
                            ContentUnavailableView(
                                "还没有标签",
                                systemImage: "tag.slash",
                                description: Text("可在这里创建标签并由 Mac Host 应用到当前选择。")
                            )
                            .listRowBackground(Color.clear)
                        } else {
                            tagSections
                        }
                    }
                }
            }
            .navigationTitle("批量标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                RemoteStatusBanner(message: model.statusMessage)
            }
            .interactiveDismissDisabled(model.isBusy)
            .accessibilityIdentifier("batch-tag-workbench")
        }
        .alert("创建并应用标签", isPresented: $isCreateTagPresented) {
            TextField("标签名称", text: $newTagName)
            Button("取消", role: .cancel) { newTagName = "" }
            Button("创建") {
                let name = newTagName
                newTagName = ""
                Task { await model.createTagAndApply(name: name) }
            }
            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Mac Host 将原子创建标签，并接受到当前 \(model.selectedAssetIDs.count) 个项目。")
        }
    }

    private var selectionSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(selectedAssets) { asset in
                        Button {
                            model.toggleSelection(asset.id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            RemoteThumbnailView(
                                data: model.thumbnailDataByAssetID[asset.id],
                                placeholder: asset.fileName ?? String(asset.id.uuidString.prefix(8)),
                                isSelected: true
                            )
                            .frame(width: 72, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.red)
                                    .padding(4)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除 \(asset.fileName ?? "未命名项目")")
                    }
                }
            }
            .frame(height: 64)

            HStack {
                Button("全选已载入") { model.selectAllLoadedAssets() }
                Spacer()
                Button("反选") { model.invertLoadedAssetSelection() }
                Spacer()
                Button("清除", role: .destructive) { model.clearLibrarySelection() }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)

            if !model.canSendCommands {
                Label("当前不是实时连接，可查看旧聚合，但标签写入已锁定。", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button {
                    isCreateTagPresented = true
                } label: {
                    Label("创建并应用标签", systemImage: "tag.badge.plus")
                }
                .disabled(!model.canSendCommands || model.isBusy)
                .accessibilityIdentifier("batch-tag-create")

                Spacer()

                Button {
                    guard model.latestUndoID != nil else { return }
                    Task {
                        let succeeded = await model.undoLatestTagDecision()
                        UINotificationFeedbackGenerator().notificationOccurred(
                            succeeded ? .success : .error
                        )
                    }
                } label: {
                    Label("撤销最近操作", systemImage: "arrow.uturn.backward")
                }
                .opacity(model.latestUndoID == nil ? 0 : 1)
                .accessibilityHidden(model.latestUndoID == nil)
                .disabled(
                    model.latestUndoID == nil
                        || !model.canSendCommands
                        || model.isBusy
                )
                .accessibilityIdentifier("batch-tag-undo")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("已选 \(model.selectedAssetIDs.count) 项")
        } footer: {
            Text("轻点缩略图可移出选择；成功决定会保留其余选择，便于继续处理其他标签。")
        }
    }

    @ViewBuilder
    private var tagSections: some View {
        ForEach(model.tagGroups) { group in
            let tags = model.tags.filter { $0.groupID == group.id }
            if !tags.isEmpty {
                Section(group.displayName) {
                    ForEach(tags) { tag in
                        RemoteBatchTagRow(tag: tag, model: model)
                    }
                }
            }
        }

        let ungrouped = model.tags.filter { tag in
            !model.tagGroups.contains(where: { $0.id == tag.groupID })
        }
        if !ungrouped.isEmpty {
            Section("其他") {
                ForEach(ungrouped) { tag in
                    RemoteBatchTagRow(tag: tag, model: model)
                }
            }
        }
    }

    private var selectedAssets: [RemoteAssetSummary] {
        model.assets.filter { model.selectedAssetIDs.contains($0.id) }
    }
}

private struct RemoteBatchTagRow: View {
    let tag: RemoteTagSummary
    @ObservedObject var model: RemoteCompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(tag.displayName, systemImage: aggregateIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(aggregateColor)
                Spacer()
                Text(aggregateHeadline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let aggregate {
                HStack(spacing: 12) {
                    Label("接受 \(aggregate.acceptedCount)", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Label("拒绝 \(aggregate.rejectedCount)", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Label("未定 \(aggregate.unknownCount)", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }

            HStack(spacing: 8) {
                decisionButton("接受", systemImage: "checkmark", action: .accept, tint: .green)
                decisionButton("拒绝", systemImage: "xmark", action: .reject, tint: .red)
                decisionButton("清除", systemImage: "eraser", action: .clear, tint: .secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("batch-tag-row-\(tag.id.uuidString)")
    }

    private var aggregate: RemoteTagSelectionAggregate? {
        model.tagSelectionAggregates[tag.id]
    }

    private var aggregateHeadline: String {
        guard let aggregate else {
            return model.capabilities?.capabilities.contains(.tagSelection) == true
                ? "正在读取状态"
                : "Host 未提供聚合"
        }
        let selectedCount = model.selectedAssetIDs.count
        if aggregate.acceptedCount == selectedCount { return "全部已接受" }
        if aggregate.rejectedCount == selectedCount { return "全部已拒绝" }
        if aggregate.unknownCount == selectedCount { return "全部未决定" }
        return "混合状态"
    }

    private var aggregateIcon: String {
        guard let aggregate else { return "tag" }
        let selectedCount = model.selectedAssetIDs.count
        if aggregate.acceptedCount == selectedCount { return "checkmark.circle.fill" }
        if aggregate.rejectedCount == selectedCount { return "xmark.circle.fill" }
        if aggregate.unknownCount == selectedCount { return "questionmark.circle" }
        return "circle.lefthalf.filled"
    }

    private var aggregateColor: Color {
        guard let aggregate else { return .primary }
        let selectedCount = model.selectedAssetIDs.count
        if aggregate.acceptedCount == selectedCount { return .green }
        if aggregate.rejectedCount == selectedCount { return .red }
        return .primary
    }

    private func decisionButton(
        _ title: String,
        systemImage: String,
        action: RemoteTagDecisionAction,
        tint: Color
    ) -> some View {
        Button {
            Task {
                let succeeded = await model.applyTagDecisionToSelection(
                    action,
                    tagID: tag.id
                )
                UINotificationFeedbackGenerator().notificationOccurred(
                    succeeded ? .success : .error
                )
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.small)
        .disabled(
            !model.canSendCommands
                || model.isBusy
                || model.selectedAssetIDs.isEmpty
        )
        .accessibilityLabel("\(title)标签 \(tag.displayName)")
    }
}

private struct RemoteLibraryFilterSheet: View {
    @ObservedObject var model: RemoteCompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("标签组合") {
                    Picker("多个条件", selection: $model.libraryTagMatchMode) {
                        Text("全部满足").tag(RemoteAssetTagMatchMode.all)
                        Text("任一满足").tag(RemoteAssetTagMatchMode.any)
                    }
                    .pickerStyle(.segmented)

                    ForEach(model.tags) { tag in
                        Picker(
                            tag.displayName,
                            selection: Binding(
                                get: { model.tagFilterMode(for: tag.id) },
                                set: { model.setTagFilterMode($0, for: tag.id) }
                            )
                        ) {
                            Text("不限").tag(RemoteLibraryTagFilterMode.none)
                            Text("已接受").tag(RemoteLibraryTagFilterMode.accepted)
                            Text("已拒绝").tag(RemoteLibraryTagFilterMode.rejected)
                            Text("排除").tag(RemoteLibraryTagFilterMode.excluded)
                        }
                    }
                }

                Section("媒体") {
                    Toggle("图片", isOn: setBinding(
                        value: .image,
                        values: $model.libraryMediaKinds
                    ))
                    Toggle("视频", isOn: setBinding(
                        value: .video,
                        values: $model.libraryMediaKinds
                    ))
                }

                Section("文件状态") {
                    Toggle("可用", isOn: availabilityBinding(.available))
                    Toggle("缺失", isOn: availabilityBinding(.missing))
                    Toggle("不可读取", isOn: availabilityBinding(.unreadable))
                    Toggle("不支持", isOn: availabilityBinding(.unsupported))
                }

                Section("标签存在性") {
                    Picker("范围", selection: $model.libraryTagPresence) {
                        Text("全部").tag(RemoteAssetTagPresence.any)
                        Text("已有标签").tag(RemoteAssetTagPresence.tagged)
                        Text("没有标签").tag(RemoteAssetTagPresence.untagged)
                    }
                }

                Section {
                    Button("重置所有高级筛选", role: .destructive) {
                        model.resetLibraryFilters()
                    }
                }
            }
            .navigationTitle("图库筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        dismiss()
                        Task { await model.reloadAssets(reset: true) }
                    }
                }
            }
        }
    }

    private func availabilityBinding(_ value: RemoteAssetAvailability) -> Binding<Bool> {
        setBinding(value: value, values: $model.libraryAvailabilities)
    }

    private func setBinding<Value: Hashable>(
        value: Value,
        values: Binding<Set<Value>>
    ) -> Binding<Bool> {
        Binding(
            get: { values.wrappedValue.contains(value) },
            set: { isEnabled in
                if isEnabled {
                    values.wrappedValue.insert(value)
                } else {
                    values.wrappedValue.remove(value)
                }
            }
        )
    }
}

private struct RemoteReviewQueueView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var previewTarget: RemotePreviewTarget?

    private var filterID: String {
        "\(model.isReviewOverviewPresented):\(model.reviewTagID?.uuidString ?? "none"):\(model.reviewSourceID?.uuidString ?? "all"):\(model.reviewMediaKind.rawValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteReviewFilterBar(
                model: model,
                showsTagPicker: !model.isReviewOverviewPresented
            )

            if model.capabilities?.capabilities.contains(.reviewQueue) != true {
                Spacer()
                ContentUnavailableView(
                    "Host 不支持远程审核",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请更新 Mac Host 后重试。")
                )
                Spacer()
            } else if model.isReviewOverviewPresented {
                reviewOverviewContent
            } else {
                reviewQueueContent
            }

            RemoteStatusBanner(
                message: model.statusMessage,
                undo: model.latestUndoID == nil
                    ? nil
                    : { Task { await model.undoLatestTagDecision() } }
            )
            if !model.isReviewOverviewPresented {
                RemoteDecisionBar(
                    isDisabled: !model.canSendCommands
                        || model.selectedReviewAssetIDs.isEmpty,
                    accept: { Task { await model.applyReviewDecision(.accept) } },
                    reject: { Task { await model.applyReviewDecision(.reject) } },
                    clear: { Task { await model.applyReviewDecision(.clear) } }
                )
            }
        }
        .task(id: filterID) {
            if model.isReviewOverviewPresented {
                await model.reloadReviewOverview()
            } else {
                await model.reloadReviewQueue(reset: true)
            }
        }
        .sheet(item: $previewTarget) { target in
            RemoteAssetPreviewView(target: target, model: model)
        }
    }

    @ViewBuilder
    private var reviewOverviewContent: some View {
        if model.reviewOverview == nil, model.isBusy {
            Spacer()
            ProgressView("正在载入审核总览…")
            Spacer()
        } else if let overview = model.reviewOverview, !overview.tags.isEmpty {
            ScrollView {
                LazyVStack(spacing: 12) {
                    HStack {
                        Label(
                            "共 \(overview.totalPendingSuggestionCount) 条待审核建议",
                            systemImage: "sparkles"
                        )
                        .font(.headline)
                        Spacer()
                    }

                    ForEach(overview.tags) { item in
                        Button {
                            Task { await model.openReviewQueue(tagID: item.id) }
                        } label: {
                            reviewOverviewCard(item)
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.canReview || item.pendingSuggestionCount == 0)
                    }
                }
                .padding()
            }
            .refreshable { await model.reloadReviewOverview() }
        } else {
            Spacer()
            ContentUnavailableView(
                "没有待审核建议",
                systemImage: "checkmark.seal",
                description: Text("Mac Host 当前没有可审核的图片或视频建议。")
            )
            Spacer()
        }
    }

    @ViewBuilder
    private var reviewQueueContent: some View {
        if model.reviewTagID == nil {
            Spacer()
            ContentUnavailableView(
                "没有可审核标签",
                systemImage: "tag",
                description: Text("返回总览选择一个有待审建议的标签。")
            )
            Spacer()
        } else if model.reviewItems.isEmpty, model.isBusy {
            Spacer()
            ProgressView("正在载入审核队列…")
            Spacer()
        } else if model.reviewItems.isEmpty {
            Spacer()
            ContentUnavailableView(
                "审核队列为空",
                systemImage: "checkmark.circle",
                description: Text("当前标签和来源没有待审核建议。")
            )
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 14
                ) {
                    ForEach(model.reviewItems) { item in
                        reviewCell(item)
                            .onAppear {
                                Task { await model.loadMoreReviewIfNeeded(current: item) }
                            }
                    }
                }
                .padding(10)
            }
            .refreshable { await model.reloadReviewQueue(reset: true) }
        }
    }

    private func reviewOverviewCard(_ item: RemoteSuggestionTagOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.displayName)
                    .font(.headline)
                Spacer()
                Text("\(item.pendingSuggestionCount) 条")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(item.pendingSuggestionCount > 0 ? Color.accentColor : Color.secondary)
            }

            HStack(spacing: 14) {
                Label("接受 \(item.acceptedSampleCount)", systemImage: "checkmark.circle")
                Label("拒绝 \(item.rejectedSampleCount)", systemImage: "xmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let total = item.totalCount, total > 0 {
                ProgressView(value: Double(item.checkedCount), total: Double(total))
            }

            HStack {
                Text(suggestionTaskStatusTitle(item.taskStatus))
                    .foregroundStyle(suggestionTaskStatusColor(item.taskStatus))
                Spacer()
                if item.pendingSuggestionCounts.personalModel > 0 {
                    Text("个人 \(item.pendingSuggestionCounts.personalModel)")
                }
                if item.pendingSuggestionCounts.standardModel > 0 {
                    Text("标准 \(item.pendingSuggestionCounts.standardModel)")
                }
            }
            .font(.caption.weight(.medium))
        }
        .padding(14)
        .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .opacity(item.canReview && item.pendingSuggestionCount > 0 ? 1 : 0.62)
    }

    private func reviewCell(_ item: RemoteReviewQueueItem) -> some View {
        let selected = model.selectedReviewAssetIDs.contains(item.assetID)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button {
                    previewTarget = RemotePreviewTarget(
                        assetID: item.assetID,
                        title: item.fileName,
                        context: .review
                    )
                } label: {
                    RemoteThumbnailView(
                        data: model.reviewThumbnailDataByAssetID[item.assetID],
                        placeholder: item.fileName ?? String(item.assetID.uuidString.prefix(8)),
                        isSelected: selected
                    )
                }
                .buttonStyle(.plain)

                Button {
                    model.toggleReviewSelection(item.assetID)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? .white : .white, selected ? Color.accentColor : .black.opacity(0.45))
                        .shadow(radius: 2)
                        .padding(7)
                }
                .buttonStyle(.plain)
            }

            Text(item.fileName ?? "未命名")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            HStack {
                Text(reviewOriginTitle(item.suggestionOrigin))
                Spacer()
                if let score = item.score {
                    Text(score.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct RemoteTagLibraryView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var searchText = ""
    @State private var nameOperation: RemoteTagNameOperation?
    @State private var draftName = ""
    @State private var pendingArchiveTag: RemoteTagSummary?
    @State private var pendingDeleteGroup: RemoteTagGroupSummary?

    var body: some View {
        List {
            Section {
                Button {
                    beginNameOperation(.createGroup)
                } label: {
                    Label("新建标签分组", systemImage: "folder.badge.plus")
                }
                .disabled(!model.canSendCommands)
            }

            ForEach(model.tagGroups) { group in
                Section {
                    let groupTags = filteredTags.filter { $0.groupID == group.id }
                    if groupTags.isEmpty {
                        Text(searchText.isEmpty ? "此分组暂无标签" : "没有匹配标签")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groupTags) { tag in
                            tagRow(tag)
                        }
                    }
                } header: {
                    groupHeader(group)
                }
            }

            let ungroupedTags = filteredTags.filter { tag in
                !model.tagGroups.contains(where: { $0.id == tag.groupID })
            }
            if !ungroupedTags.isEmpty {
                Section("其他") {
                    ForEach(ungroupedTags) { tag in
                        tagRow(tag)
                    }
                }
            }

            if model.tags.isEmpty {
                ContentUnavailableView(
                    "还没有标签",
                    systemImage: "tag.slash",
                    description: Text("可在图库选择项目后创建标签，或在 Mac 上管理标签。")
                )
                .listRowBackground(Color.clear)
            }
        }
        .searchable(text: $searchText, prompt: "搜索标签")
        .refreshable { await model.reloadTagLibrary() }
        .task { await model.reloadTagLibrary() }
        .safeAreaInset(edge: .bottom) {
            RemoteStatusBanner(
                message: model.statusMessage,
                undo: model.latestUndoID == nil
                    ? nil
                    : { Task { await model.undoLatestTagDecision() } }
            )
        }
        .alert(
            nameOperation?.title ?? "编辑名称",
            isPresented: Binding(
                get: { nameOperation != nil },
                set: { if !$0 { nameOperation = nil } }
            )
        ) {
            TextField("名称", text: $draftName)
            Button("取消", role: .cancel) {
                nameOperation = nil
                draftName = ""
            }
            Button(nameOperation?.confirmTitle ?? "保存") {
                guard let operation = nameOperation else { return }
                nameOperation = nil
                submitNameOperation(operation)
            }
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(nameOperation?.message ?? "")
        }
        .confirmationDialog(
            "归档标签？",
            isPresented: Binding(
                get: { pendingArchiveTag != nil },
                set: { if !$0 { pendingArchiveTag = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tag = pendingArchiveTag {
                Button("归档“\(tag.displayName)”", role: .destructive) {
                    pendingArchiveTag = nil
                    Task { await model.archiveTag(tagID: tag.id) }
                }
            }
            Button("取消", role: .cancel) { pendingArchiveTag = nil }
        } message: {
            Text("归档后该标签从日常图库与审核入口隐藏，Mac 仍是权威状态。")
        }
        .confirmationDialog(
            "删除标签分组？",
            isPresented: Binding(
                get: { pendingDeleteGroup != nil },
                set: { if !$0 { pendingDeleteGroup = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let group = pendingDeleteGroup {
                Button("删除“\(group.displayName)”", role: .destructive) {
                    pendingDeleteGroup = nil
                    Task { await model.deleteTagGroup(groupID: group.id) }
                }
            }
            Button("取消", role: .cancel) { pendingDeleteGroup = nil }
        } message: {
            Text("只有空的自定义分组可以删除；系统分组不会提供此操作。")
        }
    }

    private var filteredTags: [RemoteTagSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.tags }
        return model.tags.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private func groupHeader(_ group: RemoteTagGroupSummary) -> some View {
        HStack {
            Label(group.displayName, systemImage: group.isSystem ? "folder.fill" : "folder")
            Spacer()
            if !group.isSystem {
                Menu {
                    Button("重命名") { beginNameOperation(.renameGroup(group)) }
                    Button("删除", role: .destructive) { pendingDeleteGroup = group }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(!model.canSendCommands)
            }
        }
    }

    private func tagRow(_ tag: RemoteTagSummary) -> some View {
        HStack {
            Image(systemName: "tag.fill")
                .foregroundStyle(.tint)
            Text(tag.displayName)
            Spacer()
            Menu {
                Button("重命名") { beginNameOperation(.renameTag(tag)) }
                Menu("移动到分组") {
                    ForEach(model.tagGroups) { group in
                        Button {
                            Task { await model.moveTag(tagID: tag.id, to: group.id) }
                        } label: {
                            Label(
                                group.displayName,
                                systemImage: group.id == tag.groupID ? "checkmark" : "folder"
                            )
                        }
                        .disabled(group.id == tag.groupID)
                    }
                }
                Button("归档", role: .destructive) { pendingArchiveTag = tag }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .disabled(!model.canSendCommands || model.isBusy)
        }
    }

    private func beginNameOperation(_ operation: RemoteTagNameOperation) {
        draftName = operation.initialName
        nameOperation = operation
    }

    private func submitNameOperation(_ operation: RemoteTagNameOperation) {
        let name = draftName
        draftName = ""
        Task {
            switch operation {
            case .createGroup:
                await model.createTagGroup(name: name)
            case let .renameTag(tag):
                await model.renameTag(tagID: tag.id, name: name)
            case let .renameGroup(group):
                await model.renameTagGroup(groupID: group.id, name: name)
            }
        }
    }
}

private struct RemoteJobsView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var filter: RemoteJobFilter = .all
    @State private var searchText = ""
    @State private var selectedJob: RemoteJobSummary?

    var body: some View {
        Group {
            if model.capabilities?.capabilities.contains(.jobs) != true {
                ContentUnavailableView(
                    "Host 不支持远程任务",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请更新 Mac Host 后重试。")
                )
            } else if model.jobs.isEmpty {
                ContentUnavailableView(
                    "当前没有任务",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Mac Host 的分析和同步任务会显示在这里。")
                )
            } else {
                List {
                    Section {
                        RemoteJobSummaryStrip(
                            jobs: model.jobs,
                            selectedFilter: filter,
                            onSelect: { filter = $0 }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                        Picker("任务筛选", selection: $filter) {
                            ForEach(RemoteJobFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("jobs-filter")

                        if !model.canSendCommands {
                            Label(
                                "显示的是最近一次任务状态；恢复实时连接前不可操作。",
                                systemImage: "clock.badge.exclamationmark"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("jobs-stale-status")
                        }
                    }

                    if visibleJobs.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "此分类没有任务" : "没有匹配的任务",
                            systemImage: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass",
                            description: Text(emptyDescription)
                        )
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("jobs-filter-empty")
                    } else {
                        ForEach(visibleBuckets) { bucket in
                            let jobs = jobs(in: bucket)
                            if !jobs.isEmpty {
                                Section(bucket.title) {
                                    ForEach(jobs) { job in
                                        RemoteJobRow(
                                            model: model,
                                            job: job,
                                            onOpen: { selectedJob = job }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $searchText, prompt: "任务类型、状态或 ID")
                .refreshable { await model.reloadJobs() }
                .sheet(item: $selectedJob) { job in
                    NavigationStack {
                        RemoteJobDetailView(model: model, jobID: job.id)
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .task { await model.reloadJobs() }
        .safeAreaInset(edge: .bottom) {
            RemoteStatusBanner(message: model.statusMessage)
        }
    }

    private var visibleBuckets: [RemoteJobBucket] {
        if let bucket = filter.bucket {
            [bucket]
        } else {
            RemoteJobBucket.allCases
        }
    }

    private var visibleJobs: [RemoteJobSummary] {
        model.jobs.filter { job in
            filter.includes(job.state) && matchesSearch(job)
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty {
            "请调整搜索文字或任务分类。"
        } else if filter == .all {
            "Mac Host 当前没有可显示的任务。"
        } else {
            "切换到“全部”可查看其他任务。"
        }
    }

    private func jobs(in bucket: RemoteJobBucket) -> [RemoteJobSummary] {
        visibleJobs.filter { bucket.includes($0.state) }
    }

    private func matchesSearch(_ job: RemoteJobSummary) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return jobKindTitle(job.kind).localizedCaseInsensitiveContains(trimmed)
            || jobStateTitle(job.state).localizedCaseInsensitiveContains(trimmed)
            || job.id.uuidString.localizedCaseInsensitiveContains(trimmed)
    }
}

private enum RemoteJobFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .attention: "需处理"
        case .history: "历史"
        }
    }

    var bucket: RemoteJobBucket? {
        switch self {
        case .all: nil
        case .active: .active
        case .attention: .attention
        case .history: .history
        }
    }

    func includes(_ state: RemoteJobState) -> Bool {
        bucket?.includes(state) ?? true
    }
}

private enum RemoteJobBucket: String, CaseIterable, Identifiable {
    case active
    case attention
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "进行中"
        case .attention: "需处理"
        case .history: "历史"
        }
    }

    func includes(_ state: RemoteJobState) -> Bool {
        switch self {
        case .active:
            state == .pending || state == .running || state == .paused
        case .attention:
            state == .retryableFailed || state == .terminalFailed
        case .history:
            state == .completed || state == .cancelled
        }
    }
}

private struct RemoteJobSummaryStrip: View {
    let jobs: [RemoteJobSummary]
    let selectedFilter: RemoteJobFilter
    let onSelect: (RemoteJobFilter) -> Void

    var body: some View {
        HStack(spacing: 10) {
            summaryButton(filter: .active, icon: "play.circle.fill")
            summaryButton(filter: .attention, icon: "exclamationmark.triangle.fill")
            summaryButton(filter: .history, icon: "clock.fill")
        }
        .padding(.vertical, 4)
    }

    private func summaryButton(filter: RemoteJobFilter, icon: String) -> some View {
        Button {
            onSelect(selectedFilter == filter ? .all : filter)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(summaryColor(filter))
                Text("\(count(for: filter))")
                    .font(.title2.bold().monospacedDigit())
                Text(filter.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                selectedFilter == filter ? summaryColor(filter).opacity(0.14) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selectedFilter == filter ? summaryColor(filter) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title)任务 \(count(for: filter)) 个")
        .accessibilityIdentifier("jobs-summary-\(filter.rawValue)")
    }

    private func count(for filter: RemoteJobFilter) -> Int {
        jobs.filter { filter.includes($0.state) }.count
    }

    private func summaryColor(_ filter: RemoteJobFilter) -> Color {
        switch filter {
        case .active: .blue
        case .attention: .orange
        case .history, .all: .secondary
        }
    }
}

private struct RemoteJobRow: View {
    @ObservedObject var model: RemoteCompanionModel
    let job: RemoteJobSummary
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: jobKindIcon(job.kind))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(jobKindTitle(job.kind))
                            .font(.headline)
                        Text(job.id.uuidString.prefix(8).uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RemoteJobStateBadge(state: job.state)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            RemoteJobProgressView(job: job)

            if !job.availableActions.isEmpty {
                RemoteJobActionButtons(model: model, job: job)
            }
        }
        .padding(.vertical, 5)
        .accessibilityIdentifier("job-row-\(job.id.uuidString)")
    }
}

private struct RemoteJobDetailView: View {
    @ObservedObject var model: RemoteCompanionModel
    let jobID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let job = model.jobs.first(where: { $0.id == jobID }) {
                Form {
                    Section("任务") {
                        LabeledContent("类型", value: jobKindTitle(job.kind))
                        LabeledContent("状态") {
                            RemoteJobStateBadge(state: job.state)
                        }
                        LabeledContent("任务 ID") {
                            Text(job.id.uuidString.uppercased())
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    Section("进度") {
                        RemoteJobProgressView(job: job)
                    }

                    Section("Host 允许的操作") {
                        if job.availableActions.isEmpty {
                            Text("当前状态没有可用操作。")
                                .foregroundStyle(.secondary)
                        } else {
                            RemoteJobActionButtons(model: model, job: job)
                        }

                        if !model.canSendCommands {
                            Label("当前不是实时连接，操作已锁定。", systemImage: "lock.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityIdentifier("job-detail-\(job.id.uuidString)")
            } else {
                ContentUnavailableView(
                    "任务已不在 Host 列表",
                    systemImage: "arrow.clockwise.circle",
                    description: Text("关闭详情后刷新任务列表。")
                )
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            RemoteStatusBanner(message: model.statusMessage)
        }
    }
}

private struct RemoteJobProgressView: View {
    let job: RemoteJobSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let total = job.progress.totalUnitCount, total > 0 {
                ProgressView(value: boundedCompleted, total: Double(total))
                HStack {
                    Text("\(job.progress.completedUnitCount) / \(total)")
                    Spacer()
                    Text("\(completionPercent)%")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                if job.state == .running {
                    ProgressView()
                }
                Text("已处理 \(job.progress.completedUnitCount)；总量由 Host 动态确定")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("job-progress-\(job.id.uuidString)")
    }

    private var boundedCompleted: Double {
        guard let total = job.progress.totalUnitCount else { return 0 }
        return Double(min(max(job.progress.completedUnitCount, 0), total))
    }

    private var completionPercent: Int {
        guard let total = job.progress.totalUnitCount, total > 0 else { return 0 }
        return Int((boundedCompleted / Double(total) * 100).rounded())
    }
}

private struct RemoteJobStateBadge: View {
    let state: RemoteJobState

    var body: some View {
        Text(jobStateTitle(state))
            .font(.caption.weight(.semibold))
            .foregroundStyle(jobStateColor(state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(jobStateColor(state).opacity(0.12), in: Capsule())
    }
}

private struct RemoteJobActionButtons: View {
    @ObservedObject var model: RemoteCompanionModel
    let job: RemoteJobSummary
    @State private var isCancelConfirmationPresented = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(job.availableActions, id: \.rawValue) { action in
                Button(jobActionTitle(action), role: action == .cancel ? .destructive : nil) {
                    if action == .cancel {
                        isCancelConfirmationPresented = true
                    } else {
                        Task { await model.applyJobAction(action, to: job.id) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDisabled)
                .accessibilityIdentifier("job-action-\(action.rawValue)-\(job.id.uuidString)")
            }

            if model.jobActionInFlightIDs.contains(job.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在提交任务操作")
            }
        }
        .confirmationDialog(
            "取消“\(jobKindTitle(job.kind))”？",
            isPresented: $isCancelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认取消任务", role: .destructive) {
                Task { await model.applyJobAction(.cancel, to: job.id) }
            }
            .accessibilityIdentifier("job-confirm-cancel-\(job.id.uuidString)")
            Button("返回", role: .cancel) {}
        } message: {
            Text("Host 将停止这项任务；已经产生的数据不会因此删除。")
        }
    }

    private var isDisabled: Bool {
        !model.canSendCommands || model.jobActionInFlightIDs.contains(job.id)
    }
}

private struct RemoteReviewFilterBar: View {
    @ObservedObject var model: RemoteCompanionModel
    let showsTagPicker: Bool

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("全部来源") {
                    model.reviewSourceID = nil
                    reloadForCurrentMode()
                }
                ForEach(model.sources) { source in
                    Button(source.displayName) {
                        model.reviewSourceID = source.id
                        reloadForCurrentMode()
                    }
                }
            } label: {
                Label(selectedSourceTitle, systemImage: "externaldrive")
                    .lineLimit(1)
            }

            if showsTagPicker {
                Button {
                    Task { await model.showReviewOverview() }
                } label: {
                    Label("总览", systemImage: "chevron.left")
                }

                Menu {
                    ForEach(model.tags) { tag in
                        Button(tag.displayName) {
                            model.reviewTagID = tag.id
                            Task { await model.reloadReviewQueue(reset: true) }
                        }
                    }
                } label: {
                    Label(selectedTagTitle, systemImage: "tag")
                        .lineLimit(1)
                }
                .disabled(model.tags.isEmpty)
            }

            Menu {
                Button("图片") {
                    model.reviewMediaKind = .image
                    reloadForCurrentMode()
                }
                Button("视频") {
                    model.reviewMediaKind = .video
                    reloadForCurrentMode()
                }
            } label: {
                Label(
                    model.reviewMediaKind == .image ? "图片" : "视频",
                    systemImage: model.reviewMediaKind == .image ? "photo" : "video"
                )
            }

            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedSourceTitle: String {
        guard let id = model.reviewSourceID else { return "全部来源" }
        return model.sources.first(where: { $0.id == id })?.displayName ?? "来源"
    }

    private var selectedTagTitle: String {
        guard let id = model.reviewTagID else { return "选择标签" }
        return model.tags.first(where: { $0.id == id })?.displayName ?? "标签"
    }

    private func reloadForCurrentMode() {
        Task {
            if model.isReviewOverviewPresented {
                await model.reloadReviewOverview()
            } else {
                await model.reloadReviewQueue(reset: true)
            }
        }
    }
}

private struct RemoteAssetPreviewView: View {
    let target: RemotePreviewTarget
    @ObservedObject var model: RemoteCompanionModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentAssetID: UUID
    @State private var isPreviewZoomed = false
    @State private var reviewDragOffset: CGFloat = 0
    @State private var reviewDragAction: RemoteReviewDecisionAction?
    @State private var reviewActionGeneration: UInt64 = 0
    @State private var isReviewActionInFlight = false
    @State private var lastReviewDecision: RemoteReviewDecisionRecord?
    @State private var reviewCompleted = false

    init(target: RemotePreviewTarget, model: RemoteCompanionModel) {
        self.target = target
        self.model = model
        _currentAssetID = State(initialValue: target.assetID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if reviewCompleted {
                        reviewCompletionCard
                    } else {
                        preview
                        if target.context == .library, previewAssetIDs.count > 1 {
                            libraryPreviewFilmstrip
                        }
                    }

                    if !reviewCompleted, let detail = model.previewDetail {
                        previewMetadata(detail)

                        if !detail.tags.isEmpty {
                            GroupBox {
                                VStack(spacing: 0) {
                                    ForEach(Array(detail.tags.enumerated()), id: \.element.id) { index, tag in
                                        Menu {
                                            Button("接受") { applyTag(.accept, tagID: tag.tagID) }
                                            Button("拒绝") { applyTag(.reject, tagID: tag.tagID) }
                                            Button("清除决定") { applyTag(.clear, tagID: tag.tagID) }
                                        } label: {
                                            HStack {
                                                Image(systemName: inspectorTagIcon(tag.decision))
                                                    .foregroundStyle(inspectorTagColor(tag.decision))
                                                Text(tag.displayName)
                                                Spacer()
                                                Text(inspectorTagTitle(tag.decision))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Image(systemName: "chevron.up.chevron.down")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .contentShape(Rectangle())
                                            .padding(.vertical, 9)
                                        }
                                        .disabled(!model.canSendCommands || model.isBusy)

                                        if index < detail.tags.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            } label: {
                                Label("全部标签状态", systemImage: "tag")
                            }
                            .accessibilityIdentifier("preview-all-tags")
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if target.context == .review {
                        reviewSessionControls
                    } else if previewAssetIDs.count > 1 {
                        HStack {
                            Button {
                                navigate(by: -1)
                            } label: {
                                Label("上一个", systemImage: "chevron.left")
                            }
                            .disabled(isPreviewZoomed || currentIndex == 0)
                            Spacer()
                            Text("\((currentIndex ?? 0) + 1) / \(previewAssetIDs.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                navigate(by: 1)
                            } label: {
                                Label("下一个", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(
                                isPreviewZoomed || currentIndex == previewAssetIDs.count - 1
                            )
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }

                    if target.context == .library {
                        libraryTagControls
                    }
                }
                .background(.bar)
            }
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: currentAssetID) {
                guard !reviewCompleted else { return }
                await model.loadPreview(assetID: currentAssetID, mediaKindHint: currentPreviewMediaKind)
                guard !Task.isCancelled else { return }
                if target.context == .library,
                   let currentAsset = model.assets.first(where: { $0.id == currentAssetID })
                {
                    await model.loadMoreIfNeeded(current: currentAsset)
                }
                guard !Task.isCancelled else { return }
                await model.prefetchPreviews(assetIDs: adjacentPreviewAssetIDs)
            }
            .onChange(of: reviewAssetIDs) { _, nextIDs in
                reconcileReviewQueue(nextIDs)
            }
            .onDisappear {
                reviewActionGeneration &+= 1
                model.resetPreview()
            }
        }
    }

    private var libraryPreviewFilmstrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("连续浏览", systemImage: "rectangle.stack")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let currentIndex {
                    Text("第 \(currentIndex + 1) / 已载入 \(previewAssetIDs.count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.nextCursor != nil {
                    Label("还有更多", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 9) {
                        ForEach(model.assets) { asset in
                            Button {
                                selectLibraryAsset(asset.id)
                            } label: {
                                RemoteThumbnailView(
                                    data: model.thumbnailDataByAssetID[asset.id],
                                    placeholder: asset.fileName ?? String(asset.id.uuidString.prefix(8)),
                                    isSelected: asset.id == currentAssetID
                                )
                                .frame(width: 68, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(
                                            asset.id == currentAssetID
                                                ? Color.accentColor
                                                : Color.clear,
                                            lineWidth: 3
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .id(asset.id)
                            .accessibilityLabel(asset.fileName ?? "未命名项目")
                            .accessibilityValue(asset.id == currentAssetID ? "当前项目" : "")
                            .onAppear {
                                Task { await model.loadThumbnailIfNeeded(for: asset) }
                            }
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentAssetID, anchor: .center)
                }
                .onChange(of: currentAssetID) { _, nextID in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(nextID, anchor: .center)
                    }
                }
            }
            .frame(height: 60)
        }
        .padding(12)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("library-preview-filmstrip")
    }

    private func previewMetadata(_ detail: RemoteAssetDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                if let fileName = detail.fileName, !fileName.isEmpty {
                    LabeledContent("文件名", value: fileName)
                }
                LabeledContent("来源", value: detail.sourceName)
                if let relativePath = detail.relativePath, !relativePath.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("相对路径")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(relativePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("媒体类型", value: detail.mediaType)
                LabeledContent("文件状态", value: availabilityTitle(detail.availability))
                if let width = detail.width, let height = detail.height {
                    LabeledContent("像素尺寸", value: "\(width) × \(height)")
                }
                if let createdAt = detail.mediaCreatedAtMs {
                    LabeledContent("拍摄时间", value: remoteAssetDateTitle(createdAt))
                }
                if let modifiedAt = detail.mediaModifiedAtMs {
                    LabeledContent("修改时间", value: remoteAssetDateTitle(modifiedAt))
                }
                LabeledContent("内容修订", value: String(detail.contentRevision))
                LabeledContent(
                    "标签决定",
                    value: "接受 \(detail.acceptedTagCount) · 拒绝 \(detail.rejectedTagCount)"
                )
            }
            .font(.subheadline)
        } label: {
            Label("详细信息", systemImage: "info.circle")
        }
        .accessibilityIdentifier("preview-metadata")
    }

    private var libraryTagControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.tags) { tag in
                        Button {
                            model.libraryActionTagID = tag.id
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Label(
                                tag.displayName,
                                systemImage: tag.id == model.libraryActionTagID
                                    ? "checkmark"
                                    : "tag"
                            )
                        }
                    }
                } label: {
                    Label(selectedPreviewTagTitle, systemImage: "tag")
                        .lineLimit(1)
                }
                .disabled(model.tags.isEmpty)
                .accessibilityIdentifier("preview-tag-picker")

                Spacer()

                if let decision = selectedPreviewTagDecision {
                    Label(
                        inspectorTagTitle(decision),
                        systemImage: inspectorTagIcon(decision)
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(inspectorTagColor(decision))
                } else {
                    Text(model.previewDetail == nil ? "正在读取状态" : "未决定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.latestUndoID != nil {
                    Button {
                        Task { await model.undoLatestTagDecision() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!model.canSendCommands || model.isBusy)
                    .accessibilityLabel("撤销最近标签操作")
                    .accessibilityIdentifier("preview-tag-undo")
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if !model.canSendCommands {
                Label("当前不是实时连接，标签操作已锁定。", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            if let message = model.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .padding(.horizontal)
            }

            RemoteDecisionBar(
                isDisabled: !model.canSendCommands
                    || model.isBusy
                    || model.libraryActionTagID == nil,
                accept: { applySelectedTag(.accept) },
                reject: { applySelectedTag(.reject) },
                clear: { applySelectedTag(.clear) }
            )
            .padding(.top, -6)
        }
        .accessibilityIdentifier("library-preview-tag-controls")
    }

    private var currentPreviewMediaKind: RemoteAssetMediaKind? {
        if let detail = model.previewDetail, detail.assetID == currentAssetID { return detail.resolvedMediaKind }
        return model.assets.first(where: { $0.id == currentAssetID })?.resolvedMediaKind
            ?? (target.context == .review ? model.reviewMediaKind : nil)
    }

    @ViewBuilder
    private var preview: some View {
        if currentPreviewMediaKind == .video {
            RemoteVideoPreviewView(playback: model.videoPlayback, message: model.videoPreviewMessage) {
                Task { await model.loadPreview(assetID: currentAssetID, mediaKindHint: currentPreviewMediaKind) }
            }
            .frame(minHeight: 280, maxHeight: 520)
        } else if model.previewDetail?.assetID == currentAssetID,
                  model.previewDetail?.resolvedMediaKind == nil {
            ContentUnavailableView("无法识别媒体类型", systemImage: "questionmark.video",
                                   description: Text("请刷新目录或升级 Mac Host 后重试。"))
        } else if model.isLoadingPreview {
            RoundedRectangle(cornerRadius: 16)
                .fill(.secondary.opacity(0.12))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { ProgressView("正在载入预览…") }
        } else if let data = model.previewData, let image = UIImage(data: data) {
            RemoteZoomableImageView(
                image: image,
                assetID: currentAssetID,
                isZoomed: $isPreviewZoomed,
                horizontalSwipeEnabled: target.context == .library
                    ? !isPreviewZoomed
                    : !reviewControlsDisabled,
                onHorizontalDragChanged: handleNativeHorizontalDragChanged,
                onHorizontalDragEnded: handleNativeHorizontalDragEnded
            )
                .aspectRatio(
                    max(0.58, min(1.85, image.size.width / max(image.size.height, 1))),
                    contentMode: .fit
                )
                .frame(minHeight: 280, maxHeight: 520)
                .background(.black, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topTrailing) {
                    Label(
                        isPreviewZoomed ? "已放大 · 双击还原" : "双击或捏合缩放",
                        systemImage: isPreviewZoomed
                            ? "arrow.down.right.and.arrow.up.left"
                            : "plus.magnifyingglass"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
                }
                .overlay {
                    if let reviewDragAction {
                        Label(
                            reviewDragAction == .accept ? "接受" : "拒绝",
                            systemImage: reviewDragAction == .accept
                                ? "checkmark.circle.fill"
                                : "xmark.circle.fill"
                        )
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            reviewDragAction == .accept
                                ? Color.green.opacity(0.88)
                                : Color.red.opacity(0.88),
                            in: Capsule()
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: reviewDragAction == .accept ? .topLeading : .topTrailing
                        )
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .offset(x: target.context == .review ? reviewDragOffset : 0)
                .rotationEffect(
                    .degrees(target.context == .review ? Double(reviewDragOffset / 36) : 0)
                )
                .accessibilityIdentifier(
                    target.context == .review ? "review-session-preview" : "library-preview"
                )
        } else {
            ContentUnavailableView(
                "无法载入预览",
                systemImage: "photo.badge.exclamationmark",
                description: Text(model.statusMessage ?? "请确认 Mac Host 可访问此项目。")
            )
            .frame(minHeight: 260)
        }
    }

    private var reviewCompletionCard: some View {
        ContentUnavailableView {
            Label("当前队列已处理完", systemImage: "checkmark.seal.fill")
        } description: {
            Text("审核结果已由 Mac Host 确认。可以撤销上一步，或完成后返回审核总览。")
        } actions: {
            Button("返回审核队列") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .accessibilityIdentifier("review-session-complete")
    }

    private var reviewSessionControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Label("连续审核", systemImage: "rectangle.stack.badge.play")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if reviewCompleted {
                    Text("已完成")
                } else if let currentIndex {
                    Text("第 \(currentIndex + 1) / \(reviewAssetIDs.count) 项")
                } else {
                    Text("同步队列中")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("review-session-progress")

            if isReviewActionInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在等待 Mac Host 确认…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if !reviewCompleted {
                Text("右滑接受 · 左滑拒绝 · 放大时手势自动锁定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button {
                    submitReview(.reject)
                } label: {
                    Label("拒绝", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("review-session-reject")

                Button {
                    skipReviewItem()
                } label: {
                    Label("跳过", systemImage: "forward.end")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("review-session-skip")

                Button {
                    submitReview(.accept)
                } label: {
                    Label("接受", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("review-session-accept")
            }
            .disabled(reviewControlsDisabled)

            HStack {
                Button {
                    submitReview(.clear)
                } label: {
                    Label("清除当前决定", systemImage: "eraser")
                }
                .disabled(reviewControlsDisabled)

                Spacer()

                Button {
                    undoLastReviewDecision()
                } label: {
                    Label("撤销上一步", systemImage: "arrow.uturn.backward")
                }
                .disabled(
                    isReviewActionInFlight
                        || !model.canSendCommands
                        || lastReviewDecision == nil
                )
                .accessibilityIdentifier("review-session-undo")
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var reviewControlsDisabled: Bool {
        reviewCompleted
            || isPreviewZoomed
            || isReviewActionInFlight
            || model.isBusy
            || !model.canSendCommands
    }

    private var reviewAssetIDs: [UUID] {
        model.reviewItems.map(\.assetID)
    }

    private var previewAssetIDs: [UUID] {
        switch target.context {
        case .library:
            model.assets.map(\.id)
        case .review:
            model.reviewItems.map(\.assetID)
        }
    }

    private var adjacentPreviewAssetIDs: [UUID] {
        guard let currentIndex else { return [] }
        var ids: [UUID] = []
        if previewAssetIDs.indices.contains(currentIndex - 1) {
            ids.append(previewAssetIDs[currentIndex - 1])
        }
        if previewAssetIDs.indices.contains(currentIndex + 1) {
            ids.append(previewAssetIDs[currentIndex + 1])
        }
        return ids
    }

    private var selectedPreviewTagTitle: String {
        guard let tagID = model.libraryActionTagID else { return "选择操作标签" }
        return model.tags.first(where: { $0.id == tagID })?.displayName ?? "选择操作标签"
    }

    private var selectedPreviewTagDecision: RemoteInspectorTagDecision? {
        guard let tagID = model.libraryActionTagID else { return nil }
        return model.previewDetail?.tags.first(where: { $0.tagID == tagID })?.decision
    }

    private var currentIndex: Int? {
        previewAssetIDs.firstIndex(of: currentAssetID)
    }

    private var currentTitle: String {
        if let detail = model.previewDetail, detail.assetID == currentAssetID {
            return detail.fileName ?? "预览"
        }
        switch target.context {
        case .library:
            return model.assets.first(where: { $0.id == currentAssetID })?.fileName ?? "预览"
        case .review:
            return model.reviewItems.first(where: { $0.assetID == currentAssetID })?.fileName ?? "预览"
        }
    }

    private func navigate(by offset: Int) {
        guard !isPreviewZoomed else { return }
        guard let currentIndex else { return }
        let nextIndex = currentIndex + offset
        guard previewAssetIDs.indices.contains(nextIndex) else { return }
        selectLibraryAsset(previewAssetIDs[nextIndex])
    }

    private func selectLibraryAsset(_ assetID: UUID) {
        guard !isPreviewZoomed, assetID != currentAssetID else { return }
        currentAssetID = assetID
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func handleNativeHorizontalDragChanged(_ width: CGFloat) {
        guard target.context == .review else { return }
        guard !reviewControlsDisabled else { return }
        reviewDragOffset = min(190, max(-190, width))
        let nextAction: RemoteReviewDecisionAction? = if reviewDragOffset >= 88 {
            .accept
        } else if reviewDragOffset <= -88 {
            .reject
        } else {
            nil
        }
        if nextAction != reviewDragAction {
            reviewDragAction = nextAction
            if nextAction != nil {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func handleNativeHorizontalDragEnded(_ width: CGFloat) {
        guard !isPreviewZoomed else { return }
        if target.context == .library {
            if width < -60 {
                navigate(by: 1)
            } else if width > 60 {
                navigate(by: -1)
            }
            return
        }

        let action = reviewDragAction
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
            reviewDragOffset = 0
            reviewDragAction = nil
        }
        if let action {
            submitReview(action)
        }
    }

    private func submitReview(_ action: RemoteReviewDecisionAction) {
        guard !reviewControlsDisabled else { return }
        let decidedAssetID = currentAssetID
        let preferredNextAssetID = nextReviewAssetID(after: decidedAssetID)
        reviewActionGeneration &+= 1
        let generation = reviewActionGeneration
        isReviewActionInFlight = true

        Task {
            let succeeded = await model.applyReviewDecision(
                action,
                assetIDs: [decidedAssetID]
            )
            guard generation == reviewActionGeneration,
                  decidedAssetID == currentAssetID
            else { return }
            isReviewActionInFlight = false
            if succeeded {
                if let undoID = model.latestUndoID {
                    lastReviewDecision = RemoteReviewDecisionRecord(
                        assetID: decidedAssetID,
                        undoID: undoID
                    )
                } else {
                    lastReviewDecision = nil
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                advanceAfterReviewMutation(preferredNextAssetID: preferredNextAssetID)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                reconcileReviewQueue(reviewAssetIDs)
            }
        }
    }

    private func skipReviewItem() {
        guard !reviewControlsDisabled else { return }
        guard let index = reviewAssetIDs.firstIndex(of: currentAssetID) else {
            reconcileReviewQueue(reviewAssetIDs)
            return
        }
        if reviewAssetIDs.indices.contains(index + 1) {
            moveToReviewAsset(reviewAssetIDs[index + 1])
            UISelectionFeedbackGenerator().selectionChanged()
            return
        }

        guard let item = model.reviewItems.first(where: { $0.assetID == currentAssetID }),
              model.reviewNextCursor != nil
        else {
            if let first = reviewAssetIDs.first, first != currentAssetID {
                moveToReviewAsset(first)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                model.statusMessage = "当前没有更多待审核项目"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            return
        }

        reviewActionGeneration &+= 1
        let generation = reviewActionGeneration
        isReviewActionInFlight = true
        Task {
            await model.loadMoreReviewIfNeeded(current: item)
            guard generation == reviewActionGeneration,
                  currentAssetID == item.assetID
            else { return }
            isReviewActionInFlight = false
            if let next = nextReviewAssetID(after: item.assetID) {
                moveToReviewAsset(next)
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                model.statusMessage = "Host 没有返回更多待审核项目"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    private func undoLastReviewDecision() {
        guard !isReviewActionInFlight,
              model.canSendCommands,
              let decision = lastReviewDecision
        else { return }
        reviewActionGeneration &+= 1
        let generation = reviewActionGeneration
        isReviewActionInFlight = true
        Task {
            let succeeded = await model.undoLatestTagDecision(
                expectedUndoID: decision.undoID
            )
            guard generation == reviewActionGeneration else { return }
            isReviewActionInFlight = false
            if succeeded {
                lastReviewDecision = nil
                reviewCompleted = false
                let restoredAssetID: UUID?
                if reviewAssetIDs.contains(decision.assetID) {
                    restoredAssetID = decision.assetID
                } else if let first = reviewAssetIDs.first {
                    restoredAssetID = first
                } else {
                    restoredAssetID = nil
                }
                if let restoredAssetID {
                    currentAssetID = restoredAssetID
                    await model.loadPreview(assetID: restoredAssetID)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func nextReviewAssetID(after assetID: UUID) -> UUID? {
        guard let index = reviewAssetIDs.firstIndex(of: assetID),
              reviewAssetIDs.indices.contains(index + 1)
        else { return nil }
        return reviewAssetIDs[index + 1]
    }

    private func advanceAfterReviewMutation(preferredNextAssetID: UUID?) {
        if let preferredNextAssetID, reviewAssetIDs.contains(preferredNextAssetID) {
            moveToReviewAsset(preferredNextAssetID)
        } else if let first = reviewAssetIDs.first {
            moveToReviewAsset(first)
        } else {
            reviewActionGeneration &+= 1
            reviewCompleted = true
            model.resetPreview()
        }
    }

    private func moveToReviewAsset(_ assetID: UUID) {
        reviewActionGeneration &+= 1
        reviewCompleted = false
        reviewDragOffset = 0
        reviewDragAction = nil
        currentAssetID = assetID
    }

    private func reconcileReviewQueue(_ nextIDs: [UUID]) {
        guard target.context == .review, !isReviewActionInFlight else { return }
        if nextIDs.isEmpty {
            reviewActionGeneration &+= 1
            reviewCompleted = true
            model.resetPreview()
        } else if reviewCompleted || !nextIDs.contains(currentAssetID) {
            moveToReviewAsset(nextIDs[0])
        }
    }

    private func applyTag(_ action: RemoteTagDecisionAction, tagID: UUID) {
        Task {
            let succeeded = await model.applyTagDecision(
                action,
                tagID: tagID,
                assetIDs: [currentAssetID]
            )
            UINotificationFeedbackGenerator().notificationOccurred(
                succeeded ? .success : .error
            )
        }
    }

    private func applySelectedTag(_ action: RemoteTagDecisionAction) {
        guard let tagID = model.libraryActionTagID else {
            model.statusMessage = "请先选择标签"
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        applyTag(action, tagID: tagID)
    }

}

private struct RemoteZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let assetID: UUID
    @Binding var isZoomed: Bool
    let horizontalSwipeEnabled: Bool
    let onHorizontalDragChanged: (CGFloat) -> Void
    let onHorizontalDragEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.zoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = context.coordinator.imageView
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.image = image
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.installHorizontalPan(on: scrollView)
        context.coordinator.representedAssetID = assetID
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setHorizontalPanEnabled(horizontalSwipeEnabled)
        context.coordinator.imageView.image = image
        guard context.coordinator.representedAssetID != assetID else { return }
        context.coordinator.representedAssetID = assetID
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        context.coordinator.reportZoomState(false)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: RemoteZoomableImageView
        let imageView = UIImageView()
        var representedAssetID: UUID?
        private var lastReportedZoomState = false
        private weak var horizontalPan: UIPanGestureRecognizer?

        init(parent: RemoteZoomableImageView) {
            self.parent = parent
        }

        func viewForZooming(in _: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            reportZoomState(scrollView.zoomScale > scrollView.minimumZoomScale + 0.01)
        }

        func installHorizontalPan(on scrollView: UIScrollView) {
            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleHorizontalPan(_:))
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            recognizer.isEnabled = parent.horizontalSwipeEnabled
            scrollView.addGestureRecognizer(recognizer)
            horizontalPan = recognizer
        }

        func setHorizontalPanEnabled(_ enabled: Bool) {
            horizontalPan?.isEnabled = enabled
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === horizontalPan || otherGestureRecognizer === horizontalPan
        }

        @objc
        func handleHorizontalPan(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView,
                  parent.horizontalSwipeEnabled,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            else { return }
            let translation = recognizer.translation(in: scrollView)
            guard abs(translation.x) > abs(translation.y) * 1.15 else {
                if recognizer.state == .ended
                    || recognizer.state == .cancelled
                    || recognizer.state == .failed
                {
                    parent.onHorizontalDragEnded(0)
                }
                return
            }
            let width = translation.x
            switch recognizer.state {
            case .began, .changed:
                parent.onHorizontalDragChanged(width)
            case .ended:
                parent.onHorizontalDragEnded(width)
            case .cancelled, .failed:
                parent.onHorizontalDragEnded(0)
            case .possible:
                break
            @unknown default:
                parent.onHorizontalDragEnded(0)
            }
        }

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            scrollView.zoom(
                to: CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                ),
                animated: true
            )
        }

        func reportZoomState(_ zoomed: Bool) {
            guard lastReportedZoomState != zoomed else { return }
            lastReportedZoomState = zoomed
            DispatchQueue.main.async { [weak self] in
                self?.parent.isZoomed = zoomed
            }
        }

        private func centerContent(in scrollView: UIScrollView) {
            let horizontalInset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let verticalInset = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }
}

private struct RemoteDecisionBar: View {
    let isDisabled: Bool
    let accept: () -> Void
    let reject: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: accept) {
                Label("接受", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button(action: reject) {
                Label("拒绝", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button(action: clear) {
                Label("清除", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .disabled(isDisabled)
    }
}

private struct RemoteThumbnailView: View {
    let data: Data?
    let placeholder: String
    let isSelected: Bool

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.14)
                    .overlay {
                        Text(placeholder)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(6)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct RemoteStatusBanner: View {
    let message: String?
    let undo: (() -> Void)?

    init(message: String?, undo: (() -> Void)? = nil) {
        self.message = message
        self.undo = undo
    }

    var body: some View {
        if let message, !message.isEmpty {
            HStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let undo {
                    Button("撤销", action: undo)
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

private enum RemoteTagNameOperation {
    case createGroup
    case renameTag(RemoteTagSummary)
    case renameGroup(RemoteTagGroupSummary)

    var title: String {
        switch self {
        case .createGroup: "新建标签分组"
        case .renameTag: "重命名标签"
        case .renameGroup: "重命名标签分组"
        }
    }

    var message: String {
        switch self {
        case .createGroup: "分组将在 Mac Host 的权威标签库中创建。"
        case .renameTag: "新名称会同步用于图库筛选和审核。"
        case .renameGroup: "新名称会同步到所有 Companion。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .createGroup: "创建"
        case .renameTag, .renameGroup: "保存"
        }
    }

    var initialName: String {
        switch self {
        case .createGroup: ""
        case let .renameTag(tag): tag.displayName
        case let .renameGroup(group): group.displayName
        }
    }
}

private struct RemoteReviewDecisionRecord {
    let assetID: UUID
    let undoID: UUID
}

private struct RemotePreviewTarget: Identifiable {
    enum Context {
        case library
        case review
    }

    let assetID: UUID
    let title: String?
    let context: Context
    var id: UUID { assetID }
}

@MainActor
private struct PairingQRCodeScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onError: onError)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            onError(error.localizedDescription)
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void
        private let onError: (String) -> Void
        private var didFinish = false

        init(onPayload: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onPayload = onPayload
            self.onError = onError
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFinish else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue,
                      !payload.isEmpty
                else { continue }
                didFinish = true
                dataScanner.stopScanning()
                onPayload(payload)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onError(String(describing: error))
        }
    }
}

private struct PairingJSONTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(
            forTextStyle: .footnote
        ).pointSize, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.keyboardType = .asciiCapable
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

private extension View {
    func textInputAutapitalizationNever() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

private enum RemoteCompanionTab: Hashable {
    case library
    case review
    case tags
    case jobs
    case host
}

private enum RemoteLibraryGridDensity: String, CaseIterable, Identifiable {
    case comfortable
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: "大图"
        case .standard: "标准"
        case .compact: "紧凑"
        }
    }

    var systemImage: String {
        switch self {
        case .comfortable: "square.grid.2x2"
        case .standard: "square.grid.3x3"
        case .compact: "square.grid.4x3.fill"
        }
    }

    var minimumCellWidth: CGFloat {
        switch self {
        case .comfortable: 154
        case .standard: 108
        case .compact: 78
        }
    }

    var maximumCellWidth: CGFloat {
        switch self {
        case .comfortable: 240
        case .standard: 180
        case .compact: 132
        }
    }

    var denser: Self? {
        switch self {
        case .comfortable: .standard
        case .standard: .compact
        case .compact: nil
        }
    }

    var lessDense: Self? {
        switch self {
        case .comfortable: nil
        case .standard: .comfortable
        case .compact: .standard
        }
    }
}

private func librarySortTitle(_ sort: RemoteAssetSort) -> String {
    switch sort {
    case .fileNameAscending: "文件名"
    case .newest: "最新"
    case .oldest: "最早"
    case .embeddedTimeNewest: "拍摄时间最新"
    case .embeddedTimeOldest: "拍摄时间最早"
    case .fileModifiedNewest: "文件修改最新"
    case .fileModifiedOldest: "文件修改最早"
    }
}

private func sourceKindTitle(_ kind: RemoteSourceKind) -> String {
    switch kind {
    case .folder: "文件夹"
    case .photos: "Apple Photos"
    }
}

private func sourceSystemImage(_ kind: RemoteSourceKind) -> String {
    switch kind {
    case .folder: "folder"
    case .photos: "photo.stack"
    }
}

private func sourceStateTitle(_ state: RemoteSourceState) -> String {
    switch state {
    case .active: "可用"
    case .disabled: "已停用"
    case .unavailable: "不可用"
    case .authorizationRequired: "需要授权"
    }
}

private func sourceStateColor(_ state: RemoteSourceState) -> Color {
    switch state {
    case .active: .green
    case .disabled: .secondary
    case .unavailable: .red
    case .authorizationRequired: .orange
    }
}

private func remoteCapabilityTitle(_ capability: RemoteCapability) -> String {
    switch capability {
    case .sources: "来源状态"
    case .tags: "标签库"
    case .assetPages: "图库分页"
    case .folderHierarchy: "文件夹层级"
    case .assetDetail: "资产详情"
    case .assetLocalSuggestions: "本机资产建议"
    case .cloudPreviewLifecycle: "云端预览恢复"
    case .thumbnails: "缩略图"
    case .previews: "高清预览"
    case .favorites: "收藏"
    case .tagDecisions: "标签决定"
    case .tagSelection: "选择集标签统计"
    case .reviewQueue: "审核队列"
    case .reviewDecisions: "审核决定"
    case .librarySuggestions: "图库建议"
    case .trainingActivities: "训练活动"
    case .librarySlimming: "图库瘦身"
    case .sourceManagement: "来源管理"
    case .generalSettings: "通用设置"
    case .workspaceNotices: "工作区通知"
    case .jobs: "后台任务"
    case .pairing: "安全配对"
    case .events: "实时事件"
    case .localLibrarySnapshot: "本机图库目录同步"
    case .localLibraryTagOperations: "本机图库标签提交"
    case .localLibraryTagChanges: "共享标签变化回传"
    case .localLibraryCollectionMembership: "本机图库集合成员提交"
    case .localLibraryCollectionChanges: "共享集合成员变化回传"
    case .localLibraryFavoriteTarget: "本机图库收藏目标提交"
    case .localLibraryFavoriteChanges: "共享收藏目标变化回传"
    case .migrationTransfer: "分片归档接收"
    }
}

private func reviewOriginTitle(_ origin: RemoteReviewSuggestionOrigin) -> String {
    switch origin {
    case .featurePrint: "相似特征"
    case .standardModel: "标准模型"
    case .personalModel: "个人模型"
    case .personalAdamW: "增强个人模型"
    }
}

private func suggestionTaskStatusTitle(_ status: RemoteSuggestionTaskStatus) -> String {
    switch status {
    case .notReady: "样本不足"
    case .ready: "可生成"
    case .waiting: "等待中"
    case .running: "生成中"
    case .paused: "已暂停"
    case .retryableFailure: "可重试"
    case .completed: "已完成"
    case .terminalFailure: "失败"
    case .cancelled: "已取消"
    }
}

private func suggestionTaskStatusColor(_ status: RemoteSuggestionTaskStatus) -> Color {
    switch status {
    case .running: .blue
    case .completed: .green
    case .retryableFailure, .terminalFailure: .red
    case .paused, .ready: .orange
    case .notReady, .waiting, .cancelled: .secondary
    }
}

private func jobKindTitle(_ kind: RemoteJobKind) -> String {
    switch kind {
    case .folderReconcile: "文件夹同步"
    case .photosReconcile: "Photos 同步"
    case .personalizationSuggestions: "个人建议"
    case .standardSuggestions: "标准建议"
    case .librarySlimmingAnalysis: "图库瘦身分析"
    case .librarySlimmingSourceIndex: "相似索引"
    case .background: "后台任务"
    case .other: "任务"
    }
}

private func jobKindIcon(_ kind: RemoteJobKind) -> String {
    switch kind {
    case .folderReconcile: "folder.badge.gearshape"
    case .photosReconcile: "photo.stack"
    case .personalizationSuggestions: "person.crop.circle.badge.checkmark"
    case .standardSuggestions: "sparkles"
    case .librarySlimmingAnalysis: "square.stack.3d.down.right"
    case .librarySlimmingSourceIndex: "point.3.connected.trianglepath.dotted"
    case .background: "gearshape.2"
    case .other: "bolt.horizontal.circle"
    }
}

private func jobStateTitle(_ state: RemoteJobState) -> String {
    switch state {
    case .pending: "等待中"
    case .running: "运行中"
    case .paused: "已暂停"
    case .retryableFailed: "可重试"
    case .completed: "已完成"
    case .terminalFailed: "失败"
    case .cancelled: "已取消"
    }
}

private func jobStateColor(_ state: RemoteJobState) -> Color {
    switch state {
    case .running: .blue
    case .completed: .green
    case .retryableFailed, .terminalFailed: .red
    case .paused: .orange
    case .pending, .cancelled: .secondary
    }
}

private func jobActionTitle(_ action: RemoteJobAction) -> String {
    switch action {
    case .pause: "暂停"
    case .resume: "继续"
    case .cancel: "取消"
    }
}

private func availabilityTitle(_ availability: RemoteAssetAvailability) -> String {
    switch availability {
    case .available: "可用"
    case .missing: "缺失"
    case .unreadable: "不可读取"
    case .unsupported: "不支持"
    }
}

private func remoteAssetDateTitle(_ milliseconds: Int64) -> String {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        .formatted(date: .abbreviated, time: .shortened)
}

private func inspectorTagTitle(_ decision: RemoteInspectorTagDecision) -> String {
    switch decision {
    case .unknown: "未决定"
    case .accepted: "已接受"
    case .rejected: "已拒绝"
    }
}

private func inspectorTagIcon(_ decision: RemoteInspectorTagDecision) -> String {
    switch decision {
    case .unknown: "circle"
    case .accepted: "checkmark.circle.fill"
    case .rejected: "xmark.circle.fill"
    }
}

private func inspectorTagColor(_ decision: RemoteInspectorTagDecision) -> Color {
    switch decision {
    case .unknown: .secondary
    case .accepted: .green
    case .rejected: .red
    }
}
