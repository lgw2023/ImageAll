import AppKit
import Foundation
import SwiftUI

@MainActor
final class LibraryWorkspaceModel: ObservableObject {
    @Published private(set) var phase: LibraryWorkspacePhase = .loading
    @Published private(set) var sources: [LibrarySourceSummary] = []
    @Published private(set) var items: [AssetGridItemProjection] = []

    private let service: any LibraryWorkspacePort
    private var selectedSourceID: UUID?
    private var nextCursor: AssetPageCursor?
    private var started = false
    private var isLoadingMore = false

    init(service: any LibraryWorkspacePort) {
        self.service = service
    }

    var isBusy: Bool {
        phase == .loading || phase == .scanning
    }

    func start() async {
        guard !started else { return }
        started = true
        await reload(runPendingJobs: true)
    }

    func connectFolder() async {
        guard !isBusy else { return }
        phase = .scanning
        do {
            switch try await service.connectFolder() {
            case .cancelled:
                await reload(runPendingJobs: false)
            case .connected:
                await reload(runPendingJobs: true)
            }
        } catch {
            phase = .failed(.connectionFailed)
        }
    }

    func rescan() async {
        guard !isBusy, !sources.isEmpty else { return }
        phase = .scanning
        let service = service
        let sourceIDs = selectedSourceID.map { [$0] } ?? sources.map(\.id)
        do {
            try await Self.offMain {
                try service.enqueueReconcile(sourceIDs: sourceIDs)
                try service.runPendingReconcileJobs()
            }
        } catch {
            phase = .failed(.scanFailed)
            return
        }
        await loadFirstPage()
    }

    func selectSource(_ sourceID: UUID?) async {
        guard selectedSourceID != sourceID else { return }
        selectedSourceID = sourceID
        await loadFirstPage()
    }

    func loadMoreIfNeeded(currentAssetID: UUID) async {
        guard currentAssetID == items.last?.assetID,
              let cursor = nextCursor,
              !isLoadingMore
        else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let service = service
        let sourceID = selectedSourceID
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(sourceID: sourceID, cursor: cursor)
            }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            phase = .failed(.catalogFailed)
        }
    }

    func thumbnailData(assetID: UUID) async -> Data? {
        try? await service.loadThumbnail(assetID: assetID)
    }

    private func reload(runPendingJobs: Bool) async {
        phase = .loading
        let service = service
        do {
            sources = try await Self.offMain { try service.fetchSources() }
        } catch {
            phase = .failed(.catalogFailed)
            return
        }

        guard !sources.isEmpty else {
            items = []
            nextCursor = nil
            phase = .empty
            return
        }

        if runPendingJobs {
            phase = .scanning
            do {
                try await Self.offMain { try service.runPendingReconcileJobs() }
            } catch {
                phase = .failed(.scanFailed)
                return
            }
        }
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        let service = service
        let sourceID = selectedSourceID
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(sourceID: sourceID, cursor: nil)
            }
            items = page.items
            nextCursor = page.nextCursor
            phase = .content
        } catch {
            phase = .failed(.catalogFailed)
        }
    }

    private static func offMain<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}

private enum LibrarySidebarSelection: Hashable {
    case all
    case source(UUID)
}

struct LibraryWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var selection: LibrarySidebarSelection? = .all

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            content
                .navigationTitle("全部照片")
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹", systemImage: "folder.badge.plus")
                }
                .disabled(model.isBusy)

                Button {
                    Task { await model.rescan() }
                } label: {
                    Label("立即重扫", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || model.sources.isEmpty)
            }
        }
        .task { await model.start() }
        .onChange(of: selection) { _, newValue in
            Task {
                switch newValue {
                case .all, .none:
                    await model.selectSource(nil)
                case let .source(sourceID):
                    await model.selectSource(sourceID)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("图库") {
                Label("全部照片", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySidebarSelection.all)
            }
            Section("来源") {
                ForEach(model.sources) { source in
                    Label(source.displayName, systemImage: sourceIcon(source.state))
                        .tag(LibrarySidebarSelection.source(source.id))
                }
                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ImageAll")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在打开图库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ProgressView("正在扫描照片…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("ImageAll 在原位置读取照片", systemImage: "photo.stack")
            } description: {
                Text("不会导入、移动、重命名或删除原图。索引、标签和缩略图保存在 ImageAll 自己的应用容器中。")
            } actions: {
                Button("连接照片文件夹…") {
                    Task { await model.connectFolder() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .content:
            if model.items.isEmpty {
                ContentUnavailableView {
                    Label("没有支持的照片", systemImage: "photo")
                } description: {
                    Text("支持 JPEG、PNG、HEIC/HEIF、TIFF 和 WebP。")
                } actions: {
                    Button("立即重扫") {
                        Task { await model.rescan() }
                    }
                }
            } else {
                assetGrid
            }
        case let .failed(error):
            ContentUnavailableView {
                Label(errorTitle(error), systemImage: "exclamationmark.triangle")
            } description: {
                Text("原照片没有被修改。请检查文件夹是否仍在线并重试。")
            } actions: {
                Button("重试") {
                    Task { await model.rescan() }
                }
                .disabled(model.sources.isEmpty)
            }
        }
    }

    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)],
                spacing: 8
            ) {
                ForEach(model.items, id: \.assetID) { item in
                    AssetThumbnailView(item: item, model: model)
                        .task {
                            await model.loadMoreIfNeeded(currentAssetID: item.assetID)
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sourceIcon(_ state: SourceState) -> String {
        switch state {
        case .active: return "folder"
        case .unavailable: return "externaldrive.badge.exclamationmark"
        case .authorizationRequired: return "lock.trianglebadge.exclamationmark"
        case .disabled: return "pause.circle"
        }
    }

    private func errorTitle(_ error: LibraryWorkspaceSafeError) -> String {
        switch error {
        case .connectionFailed: return "无法连接文件夹"
        case .scanFailed: return "扫描未完成"
        case .catalogFailed: return "无法读取图库"
        }
    }
}

private struct AssetThumbnailView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: placeholderIcon)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(item.fileName ?? "照片")
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: item.assetID) {
            guard item.availability == .available,
                  let data = await model.thumbnailData(assetID: item.assetID)
            else {
                return
            }
            image = NSImage(data: data)
        }
    }

    private var placeholderIcon: String {
        switch item.availability {
        case .available: return "photo"
        case .missing: return "questionmark.folder"
        case .unreadable: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        }
    }
}
