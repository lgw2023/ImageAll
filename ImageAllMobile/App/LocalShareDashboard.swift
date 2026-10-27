import SwiftUI
import Photos
import UIKit

enum LocalShareSheet: String, Identifiable {
    case selection, connection, newContent, more, advanced, macNextStep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .selection: "已选内容"
        case .connection: "连接目标 Mac"
        case .newContent: "导入新增内容"
        case .more: "更多操作"
        case .advanced: "高级迁移"
        case .macNextStep: "Mac 导入与浏览"
        }
    }
}

/// Shared by the real page and explicit synthetic UI acceptance. No model is constructed here.
struct LocalShareDashboard<Options: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let photoCount: Int
    let videoCount: Int
    let target: String
    let connection: String
    let presentation: LocalSharePresentation
    let detail: String?
    let progress: String?
    let busy: Bool
    let conflictCount: Int
    var previewItems: [LocalShareItem] = []
    var canPrepareNewContent = false
    let open: (LocalShareSheet) -> Void
    let perform: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        List {
            if canPrepareNewContent {
                Section {
                    Button { open(.newContent) } label: {
                        Label("导入新增内容", systemImage: "plus.circle.fill").font(.headline)
                    }
                    .disabled(busy).accessibilityIdentifier("share.newContent")
                    Text("预览上次任务范围之外的照片与视频，确认数量后再发送。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button { open(.selection) } label: {
                    HStack(spacing: 14) {
                        if !dynamicTypeSize.isAccessibilitySize {
                            if previewItems.isEmpty {
                                Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.tint)
                                    .frame(width: 88, height: 88)
                            } else {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                                    ForEach(Array(previewItems.prefix(4))) { item in
                                        Color.clear.aspectRatio(1, contentMode: .fit)
                                            .overlay { LocalPhotoThumbnail(item: item).clipped() }
                                    }
                                }.frame(width: 88).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("已选 \(photoCount + videoCount) 项")
                                .font(dynamicTypeSize.isAccessibilitySize ? .headline : .title2.bold())
                                .foregroundStyle(Color.primary)
                            Text("\(photoCount) 张照片 · \(videoCount) 个视频").font(.subheadline).foregroundStyle(Color.secondary)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(busy ? "任务期间可预览，选片暂时锁定" : "预览与批量管理").font(.caption).foregroundStyle(Color.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if !dynamicTypeSize.isAccessibilitySize { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 4)
                }.buttonStyle(.borderless).accessibilityIdentifier("share.selection")
            }
            Section("目标 Mac") {
                Button { open(.connection) } label: {
                    HStack(alignment: .top) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target).font(.headline).foregroundStyle(Color.primary)
                            Text(connection).font(.subheadline).foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.borderless).accessibilityIdentifier("share.connection")
            }
            Section("当前任务") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(presentation.title, systemImage: taskSymbol)
                        .font(.headline).foregroundStyle(presentation.isError ? Color.orange : Color.primary)
                    Text(presentation.message).font(.subheadline)
                    if presentation.isError, let detail {
                        Text(detail).font(.footnote).foregroundStyle(.orange).lineLimit(2)
                    }
                    if let progress {
                        Text(progress).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let detail {
                        DisclosureGroup(presentation.isError ? "查看失败原因" : "查看任务详情") {
                            Text(detail).font(.footnote).textSelection(.enabled)
                        }
                    }
                    if conflictCount > 0 {
                        Button("处理 \(conflictCount) 项整理信息冲突") { open(.more) }.disabled(busy)
                    }
                }.padding(.vertical, 3)
            }.accessibilityIdentifier("share.task")
            options()
            Section {} footer: {
                Text("照片与整理信息同批发送。手机原件保留，不下载 iCloud 原件。")
            }
        }
        .navigationTitle("待分享")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("更多操作", systemImage: "ellipsis.circle") { open(.more) }
                        .disabled(busy).accessibilityIdentifier("share.more")
                    Button("高级迁移与来源核对", systemImage: "checkmark.shield") { open(.advanced) }
                        .disabled(busy).accessibilityIdentifier("share.advanced")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("待分享操作")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                primaryButton.disabled(!presentation.isEnabled)
                .accessibilityIdentifier("share.primary")
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(busy ? "暂停后保留已落盘进度" : "按当前状态手动继续")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var taskSymbol: String {
        switch presentation.action {
        case .resume: "pause.circle.fill"
        case .retry: "exclamationmark.triangle.fill"
        case .pause: "arrow.up.circle.fill"
        case .macNextStep: "checkmark.circle.fill"
        case .connect: "desktopcomputer"
        case .permission: "lock.shield"
        default: "arrow.up.doc"
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if #available(iOS 26, *) { actionButton.buttonStyle(.glassProminent) }
        else { actionButton.buttonStyle(.borderedProminent) }
    }
    private var actionButton: some View {
        Button(action: perform) {
            Text(presentation.buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
        }.buttonBorderShape(.capsule).controlSize(.large)
    }
}

struct LocalShareItem: Identifiable {
    let id: UUID
    let localIdentifier: String?
    let isVideo: Bool
    let date: Date?
    var isFavorite = false
    var fixtureIndex: Int? = nil
}

struct LocalShareSelectionPage<AddContent: View>: View {
    @Environment(\.dismiss) private var dismiss
    let items: [LocalShareItem]
    let locked: Bool
    let remove: (Set<UUID>) async -> Int
    @ViewBuilder let addContent: () -> AddContent
    @State private var selected = Set<UUID>()
    @State private var removing = false
    @State private var message: String?
    @State private var confirmsRemoval = false
    @State private var preview: LocalShareItem?
    @State private var selecting = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(items.count) 项 · \(items.filter { !$0.isVideo }.count) 张照片 · \(items.filter(\.isVideo).count) 个视频")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if locked {
                        Label("任务执行中，可预览。暂停后才能更改选片。", systemImage: "lock.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if !selecting { addContent() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(.horizontal)
                if items.isEmpty {
                    ContentUnavailableView("还没有待分享内容", systemImage: "photo.on.rectangle",
                                           description: Text("先添加照片与视频，再返回待分享发起导入。"))
                } else {
                    LocalPhotoGrid(items: items) { item in
                        Button {
                            if selecting && !locked {
                                if !selected.insert(item.id).inserted { selected.remove(item.id) }
                            } else { preview = item }
                        } label: {
                            LocalPhotoTile(item: item, selecting: selecting && !locked, selected: selected.contains(item.id))
                        }.buttonStyle(.plain).disabled(removing)
                    }
                }
                Text("移出只更改待分享范围，系统照片原件保留。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
            }.padding(.top, 12)
        }
        .navigationTitle("已选内容")
        .toolbar {
            if !locked {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(selected.count == items.count && !items.isEmpty ? "取消全选" : "全选") {
                            selected = selected.count == items.count ? [] : Set(items.map(\.id))
                        }.disabled(removing)
                    } else {
                        Button("选择") { selecting = true }.disabled(items.isEmpty || removing)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(selecting ? "取消" : "完成") {
                    if selecting { selecting = false; selected.removeAll() }
                    else { dismiss() }
                }.disabled(removing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting && !locked {
                VStack(spacing: 8) {
                    Text("已选择 \(selected.count) 项").font(.subheadline.bold())
                    Button(removing ? "正在移出…" : "移出待分享") { confirmsRemoval = true }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(removing || selected.isEmpty)
                }.frame(maxWidth: .infinity).padding().background(.bar)
            }
        }
        .confirmationDialog("将 \(selected.count) 项移出待分享？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("移出范围，保留照片") {
                guard !locked, !removing else { return }
                removing = true
                let ids = selected
                Task {
                    let count = await remove(ids)
                    selected.subtract(ids)
                    selecting = false
                    message = "已移出 \(count) 项，系统照片原件保留。" + (count < ids.count ? " 部分项目未完成，请核对后重试。" : "")
                    removing = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("这会改变后续导入范围；不会删除照片、清空 Mac 接收批次或重置旧进度。") }
        .sheet(item: $preview) { item in
            NavigationStack {
                LocalPhotoThumbnail(item: item, preview: true)
                    .background(Color.black).navigationTitle(item.isVideo ? "视频封面预览" : "照片预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
            }.environment(\.colorScheme, .dark)
        }
        .onChange(of: locked) { _, locked in if locked { selecting = false; selected.removeAll() } }
        .onChange(of: items.map(\.id)) { _, ids in selected.formIntersection(Set(ids)) }
        .interactiveDismissDisabled(removing)
    }
}

struct LocalShareMacNextStep: View {
    var isBrowsable = false
    var macOwnsProcessing = false
    var body: some View {
        List {
            if isBrowsable {
                Section("在 Mac 浏览已导入内容") {
                    Label("打开主窗口左侧“iPhone · 已导入 Mac”", systemImage: "photo.on.rectangle")
                    Text("可以浏览照片、播放视频，并展开来源相簿。")
                }
            } else if macOwnsProcessing {
                Section("Mac 会独立完成") {
                    Label("手机可以拔线或关闭 App", systemImage: "cable.connector")
                    Text("保持 Mac ImageAll 运行、目标磁盘连接。在 Mac“设置 → 设备与导入”查看核验、入库和收尾进度；遇到问题也在 Mac 重试，无需再点一次导入。")
                }
            } else {
            Section("需要在 Mac 入库时") {
                Label("1. 打开 Mac“设置 → 设备与导入”", systemImage: "desktopcomputer")
                Label("2. 选中已接收批次，点击“导入照片与信息”", systemImage: "square.and.arrow.down")
                Label("3. 打开副本，核对照片、红心、相簿与标签／集合", systemImage: "checkmark.circle")
            }
            }
            Text("页面连接原 Mac 后会刷新入库与发布结果。可浏览状态表示来源已发布，不代表此刻重新校验所有原件，也不构成删除手机原件的依据。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
/// Explicit opt-in, independent fixture. Does not instantiate Photos, a library store,
/// companion credentials, transport or any existing archive.
struct LocalShareUIProbeView: View {
    enum Scenario: String, CaseIterable {
        case empty, permission, limited, disconnected, consent, ready, preparing, transferring, paused, failed, received
        var name: String {
            switch self {
            case .empty: "无选择"
            case .permission: "未授权"
            case .limited: "有限权限"
            case .disconnected: "未连接"
            case .consent: "等待确认"
            case .ready: "2,889 项就绪"
            case .preparing: "准备中"
            case .transferring: "传输中"
            case .paused: "已暂停"
            case .failed: "失败"
            case .received: "Mac 已接收"
            }
        }
    }
    @State private var scenario: Scenario = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--share-ui-probe"), i + 1 < args.count else { return .ready }
        return Scenario(rawValue: args[i + 1]) ?? .ready
    }()
    @State private var sheet: LocalShareSheet?
    @State private var includeCatalog = true
    @State private var items: [LocalShareItem] = {
        let unavailablePreview = ProcessInfo.processInfo.arguments.contains("--preview-unavailable")
        return (0..<2_889).map { i -> LocalShareItem in
            let fixtureIndex: Int? = i == 0 && unavailablePreview ? nil : i
            return LocalShareItem(id: UUID(), localIdentifier: nil, isVideo: i >= 2_700,
                date: Date(timeIntervalSince1970: 1_759_000_000 - Double(i * 86_400)),
                isFavorite: i.isMultiple(of: 5), fixtureIndex: fixtureIndex)
        }
    }()
    private var busy: Bool { scenario == .preparing || scenario == .transferring }
    private var task: LocalShareTask {
        var task = LocalShareTask()
        if [.preparing, .transferring, .paused, .failed, .received].contains(scenario) {
            task.begin(itemCount: 2_889, target: "合成 Mac")
            switch scenario {
            case .paused: task.pause()
            case .failed: task.phase = .failed; task.detail = "原件核对未完成，请恢复原范围和连接后重试。旧进度保留。"
            case .received: task.phase = .received
            default: break
            }
        }
        return task
    }
    private var presentation: LocalSharePresentation {
        .resolve(task: task, selectedCount: scenario == .empty ? 0 : items.count,
            canReadPhotos: scenario != .permission, needsFullAccess: includeCatalog && scenario == .limited,
            connected: ![.disconnected, .consent].contains(scenario), awaitingConsent: scenario == .consent,
            otherWork: false, selectionMatches: true,
            transferPhase: scenario == .transferring ? "传输原件" : "核对续传目录与原件")
    }
    var body: some View {
        TabView {
            NavigationStack {
                if ProcessInfo.processInfo.arguments.contains("--photos-ui-probe") {
                    LocalPhotoLibraryContent(items: items, sharedCount: items.count,
                        limited: false, hasMore: false, loadMore: {}) { item in
                        LocalPhotoThumbnail(item: item, preview: true)
                            .background(Color.black)
                            .navigationTitle(item.isVideo ? "视频封面预览" : "照片预览")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .navigationTitle("此 iPhone")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { NavigationLink("待分享") { dashboard } }
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                List {
                                    Section("标签") { Text("旅行"); Text("家人") }
                                    Section("ImageAll 集合") { Text("周末回忆"); Text("海边") }
                                    Text("合成整理展示，不写入本机整理库。")
                                }.navigationTitle("整理")
                            } label: { Image(systemName: "square.stack") }
                            .accessibilityLabel("标签与集合")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Text("合成模式不执行刷新、权限或备份。")
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                } else { dashboard }
            }.tabItem { Label("此 iPhone", systemImage: "iphone.gen3") }
            Text("合成模式不创建 Mac 连接").tabItem { Label("Mac 图库", systemImage: "desktopcomputer") }
        }
    }

    private var dashboard: some View {
                LocalShareDashboard(photoCount: scenario == .empty ? 0 : items.filter { !$0.isVideo }.count,
                    videoCount: scenario == .empty ? 0 : items.filter(\.isVideo).count, target: "合成 Mac",
                    connection: "USB 有线 · " + ([.disconnected, .consent].contains(scenario) ? "未连接" : "已连接"),
                    presentation: presentation, detail: task.detail,
                    progress: busy ? (scenario == .transferring ? "已确认原件 128 MiB · 传输均速 2 MiB/s · 合成数据" : "核对续传目录与原件") : nil,
                    busy: busy, conflictCount: 0, previewItems: scenario == .empty ? [] : Array(items.prefix(4)), open: { sheet = $0 }, perform: {
                        switch presentation.action {
                        case .pause: scenario = .paused
                        case .start, .resume, .retry: scenario = .preparing
                        case .connect: sheet = .connection
                        case .select, .permission: sheet = .selection
                        case .macNextStep: sheet = .macNextStep
                        case .none: break
                        }
                    }) {
                    Section("导入选项") {
                        Toggle("包含相簿目录（含空相簿）", isOn: $includeCatalog).disabled(busy)
                        if includeCatalog {
                            Text("需完整照片权限。只传输已选媒体，目录选项不扩大选片范围。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if scenario == .limited { Text("有限照片访问：来源相簿不可读取。").font(.footnote) }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("合成状态") {
                            ForEach(Scenario.allCases, id: \.self) { value in Button(value.name) { scenario = value } }
                        }
                    }
                }
                .sheet(item: $sheet) { page in
                    NavigationStack {
                        Group {
                            switch page {
                            case .selection:
                                LocalShareSelectionPage(items: scenario == .empty ? [] : items, locked: busy, remove: { ids in
                                    let count = items.filter { ids.contains($0.id) }.count
                                    items.removeAll { ids.contains($0.id) }
                                    return count
                                }) { Text("仅合成数据，不读取照片或连接 Mac。") }
                            case .macNextStep: LocalShareMacNextStep()
                            case .newContent: Text("合成预览，不读取照片或创建任务。")
                            default: Text("合成入口：\(page.title)。关闭弹层后任务状态保留。")
                            }
                        }
                        .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            if page != .selection {
                                ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } }
                            }
                        }
                    }
                }
    }
}
#endif
