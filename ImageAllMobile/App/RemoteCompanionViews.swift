import ImageAllRemoteProtocol
import SwiftUI
import UIKit
import Vision
import VisionKit

struct RemoteCompanionRootView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var isScannerPresented = false
    @State private var scannerMessage: String?

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
    }

    private var connectedTabs: some View {
        TabView {
            NavigationStack {
                RemoteLibraryView(model: model)
                    .navigationTitle("图库")
                    .toolbar { disconnectToolbar }
            }
            .tabItem { Label("图库", systemImage: "photo.on.rectangle.angled") }

            NavigationStack {
                RemoteReviewQueueView(model: model)
                    .navigationTitle("审核")
                    .toolbar { disconnectToolbar }
            }
            .tabItem { Label("审核", systemImage: "checklist") }

            NavigationStack {
                RemoteJobsView(model: model)
                    .navigationTitle("任务")
                    .toolbar { disconnectToolbar }
            }
            .tabItem { Label("任务", systemImage: "bolt.horizontal.circle") }
        }
    }

    @ToolbarContentBuilder
    private var disconnectToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("断开") { model.disconnect() }
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

private struct RemoteLibraryView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var previewTarget: RemotePreviewTarget?

    var body: some View {
        VStack(spacing: 0) {
            RemoteFilterBar(model: model, showsReviewReload: false)

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
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                        ],
                        spacing: 12
                    ) {
                        ForEach(model.assets) { asset in
                            libraryCell(asset)
                                .onAppear {
                                    Task { await model.loadMoreIfNeeded(current: asset) }
                                }
                        }
                    }
                    .padding(8)
                }
                .refreshable { await model.reloadAssets(reset: true) }
            }

            RemoteStatusBanner(message: model.statusMessage)
            RemoteDecisionBar(
                isDisabled: model.selectedAssetIDs.isEmpty || model.selectedTagID == nil,
                accept: { Task { await model.applyTagDecision(.accept) } },
                reject: { Task { await model.applyTagDecision(.reject) } },
                clear: { Task { await model.applyTagDecision(.clear) } }
            )
        }
        .sheet(item: $previewTarget) { target in
            RemoteAssetPreviewView(target: target, model: model)
        }
    }

    private func libraryCell(_ asset: RemoteAssetSummary) -> some View {
        let selected = model.selectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                Button {
                    previewTarget = RemotePreviewTarget(
                        assetID: asset.id,
                        title: asset.fileName,
                        context: .library
                    )
                } label: {
                    RemoteThumbnailView(
                        data: model.thumbnailDataByAssetID[asset.id],
                        placeholder: asset.fileName ?? String(asset.id.uuidString.prefix(8)),
                        isSelected: selected
                    )
                }
                .buttonStyle(.plain)

                Button {
                    model.toggleSelection(asset.id)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? .white : .white, selected ? Color.accentColor : .black.opacity(0.45))
                        .shadow(radius: 2)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "取消选择" : "选择")
            }

            Text(asset.fileName ?? "未命名")
                .font(.caption)
                .lineLimit(1)
        }
    }
}

private struct RemoteReviewQueueView: View {
    @ObservedObject var model: RemoteCompanionModel
    @State private var previewTarget: RemotePreviewTarget?

    private var filterID: String {
        "\(model.selectedTagID?.uuidString ?? "none"):\(model.selectedSourceID?.uuidString ?? "all")"
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteFilterBar(model: model, showsReviewReload: true)

            if model.capabilities?.capabilities.contains(.reviewQueue) != true {
                Spacer()
                ContentUnavailableView(
                    "Host 不支持远程审核",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请更新 Mac Host 后重试。")
                )
                Spacer()
            } else if model.selectedTagID == nil {
                Spacer()
                ContentUnavailableView(
                    "没有可审核标签",
                    systemImage: "tag",
                    description: Text("先在 Mac 上创建或启用标签。")
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

            RemoteStatusBanner(message: model.statusMessage)
            RemoteDecisionBar(
                isDisabled: model.selectedReviewAssetIDs.isEmpty,
                accept: { Task { await model.applyReviewDecision(.accept) } },
                reject: { Task { await model.applyReviewDecision(.reject) } },
                clear: { Task { await model.applyReviewDecision(.clear) } }
            )
        }
        .task(id: filterID) {
            await model.reloadReviewQueue(reset: true)
        }
        .sheet(item: $previewTarget) { target in
            RemoteAssetPreviewView(target: target, model: model)
        }
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

private struct RemoteJobsView: View {
    @ObservedObject var model: RemoteCompanionModel

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
                List(model.jobs) { job in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(jobKindTitle(job.kind))
                                .font(.headline)
                            Spacer()
                            Text(jobStateTitle(job.state))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(jobStateColor(job.state))
                        }

                        if let total = job.progress.totalUnitCount, total > 0 {
                            ProgressView(
                                value: Double(job.progress.completedUnitCount),
                                total: Double(total)
                            )
                            Text("\(job.progress.completedUnitCount) / \(total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("已完成 \(job.progress.completedUnitCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if !job.availableActions.isEmpty {
                            HStack {
                                ForEach(Array(job.availableActions.enumerated()), id: \.offset) { _, action in
                                    Button(jobActionTitle(action)) {
                                        Task { await model.applyJobAction(action, to: job.id) }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.jobActionInFlightIDs.contains(job.id))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .refreshable { await model.reloadJobs() }
            }
        }
        .task { await model.reloadJobs() }
        .safeAreaInset(edge: .bottom) {
            RemoteStatusBanner(message: model.statusMessage)
        }
    }
}

private struct RemoteFilterBar: View {
    @ObservedObject var model: RemoteCompanionModel
    let showsReviewReload: Bool

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("全部来源") {
                    model.selectedSourceID = nil
                    Task {
                        if showsReviewReload {
                            await model.reloadReviewQueue(reset: true)
                        } else {
                            await model.reloadAssets(reset: true)
                        }
                    }
                }
                ForEach(model.sources) { source in
                    Button(source.displayName) {
                        model.selectedSourceID = source.id
                        Task {
                            if showsReviewReload {
                                await model.reloadReviewQueue(reset: true)
                            } else {
                                await model.reloadAssets(reset: true)
                            }
                        }
                    }
                }
            } label: {
                Label(selectedSourceTitle, systemImage: "externaldrive")
                    .lineLimit(1)
            }

            Menu {
                ForEach(model.tags) { tag in
                    Button(tag.displayName) {
                        model.selectedTagID = tag.id
                        if showsReviewReload {
                            Task { await model.reloadReviewQueue(reset: true) }
                        }
                    }
                }
            } label: {
                Label(selectedTagTitle, systemImage: "tag")
                    .lineLimit(1)
            }
            .disabled(model.tags.isEmpty)

            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedSourceTitle: String {
        guard let id = model.selectedSourceID else { return "全部来源" }
        return model.sources.first(where: { $0.id == id })?.displayName ?? "来源"
    }

    private var selectedTagTitle: String {
        guard let id = model.selectedTagID else { return "选择标签" }
        return model.tags.first(where: { $0.id == id })?.displayName ?? "标签"
    }
}

private struct RemoteAssetPreviewView: View {
    let target: RemotePreviewTarget
    @ObservedObject var model: RemoteCompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview

                    if let detail = model.previewDetail {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("来源", value: detail.sourceName)
                            LabeledContent("类型", value: detail.mediaType)
                            LabeledContent("状态", value: availabilityTitle(detail.availability))
                            if let width = detail.width, let height = detail.height {
                                LabeledContent("尺寸", value: "\(width) × \(height)")
                            }
                            LabeledContent("已接受标签", value: String(detail.acceptedTagCount))
                            LabeledContent("已拒绝标签", value: String(detail.rejectedTagCount))
                        }
                        .font(.subheadline)

                        if !detail.tags.isEmpty {
                            Divider()
                            Text("标签状态")
                                .font(.headline)
                            ForEach(detail.tags) { tag in
                                HStack {
                                    Image(systemName: inspectorTagIcon(tag.decision))
                                        .foregroundStyle(inspectorTagColor(tag.decision))
                                    Text(tag.displayName)
                                    Spacer()
                                    Text(inspectorTagTitle(tag.decision))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                RemoteDecisionBar(
                    isDisabled: model.isBusy || model.selectedTagID == nil,
                    accept: { apply(.accept) },
                    reject: { apply(.reject) },
                    clear: { apply(.clear) }
                )
                .background(.bar)
            }
            .navigationTitle(target.title ?? "预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: target.assetID) {
                await model.loadPreview(assetID: target.assetID)
            }
            .onDisappear { model.resetPreview() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if model.isLoadingPreview {
            RoundedRectangle(cornerRadius: 16)
                .fill(.secondary.opacity(0.12))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { ProgressView("正在载入预览…") }
        } else if let data = model.previewData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ContentUnavailableView(
                "无法载入预览",
                systemImage: "photo.badge.exclamationmark",
                description: Text(model.statusMessage ?? "请确认 Mac Host 可访问此项目。")
            )
            .frame(minHeight: 260)
        }
    }

    private func apply(_ action: RemoteReviewDecisionAction) {
        Task {
            if target.context == .review {
                await model.applyReviewDecision(action, assetIDs: [target.assetID])
            } else {
                await model.applyTagDecision(
                    tagAction(action),
                    assetIDs: [target.assetID]
                )
            }
            dismiss()
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

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }
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

private func tagAction(_ action: RemoteReviewDecisionAction) -> RemoteTagDecisionAction {
    switch action {
    case .accept: .accept
    case .reject: .reject
    case .clear: .clear
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
