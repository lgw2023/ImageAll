import AppKit
import Foundation
import SwiftUI
import WebKit

struct WorldMapCluster: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let longitude: Double
    let latitude: Double
    let photoCount: Int
    let gpsCount: Int
    let tagCount: Int
    let displayName: String
}

struct WorldMapViewport: Codable, Equatable, Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
    let centerLongitude: Double
    let centerLatitude: Double
    let zoom: Double
    let bearing: Double
    let pitch: Double

    var catalogQuery: WorldMapCatalogQuery {
        WorldMapCatalogQuery(
            bounds: WorldMapCatalogBounds(
                west: west,
                south: south,
                east: east,
                north: north
            )
        )
    }
}

struct WorldMapNavigationState: Equatable, Sendable {
    var viewport: WorldMapViewport?
    var selectedClusterID: String?

    static let empty = WorldMapNavigationState(
        viewport: nil,
        selectedClusterID: nil
    )
}

enum WorldMapBridgeEvent: Equatable, Sendable {
    case ready(webGL2Available: Bool)
    case cameraChanged(WorldMapViewport)
    case clusterClicked(id: String)
    case renderError(message: String)
}

enum WorldMapBridgeDecodingError: Error, Equatable {
    case malformedPayload
    case unsupportedEvent(String)
}

enum WorldMapBridgeDecoder {
    private struct Envelope: Decodable {
        let type: String
        let webgl2Available: Bool?
        let viewport: WorldMapViewport?
        let clusterID: String?
        let message: String?
    }

    static func decode(data: Data) throws -> WorldMapBridgeEvent {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw WorldMapBridgeDecodingError.malformedPayload
        }

        switch envelope.type {
        case "ready":
            guard let webgl2Available = envelope.webgl2Available else {
                throw WorldMapBridgeDecodingError.malformedPayload
            }
            return .ready(webGL2Available: webgl2Available)
        case "cameraChanged":
            guard let viewport = envelope.viewport else {
                throw WorldMapBridgeDecodingError.malformedPayload
            }
            return .cameraChanged(viewport)
        case "clusterClicked":
            guard let clusterID = envelope.clusterID, !clusterID.isEmpty else {
                throw WorldMapBridgeDecodingError.malformedPayload
            }
            return .clusterClicked(id: clusterID)
        case "renderError":
            guard let message = envelope.message, !message.isEmpty else {
                throw WorldMapBridgeDecodingError.malformedPayload
            }
            return .renderError(message: message)
        default:
            throw WorldMapBridgeDecodingError.unsupportedEvent(envelope.type)
        }
    }
}

enum WorldMapDemoData {
    private struct Hub {
        let name: String
        let longitude: Double
        let latitude: Double
    }

    private struct Generator {
        var state: UInt64

        mutating func nextUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
    }

    private static let hubs = [
        Hub(name: "北京", longitude: 116.4074, latitude: 39.9042),
        Hub(name: "上海", longitude: 121.4737, latitude: 31.2304),
        Hub(name: "杭州", longitude: 120.1551, latitude: 30.2741),
        Hub(name: "成都", longitude: 104.0665, latitude: 30.5728),
        Hub(name: "香港", longitude: 114.1694, latitude: 22.3193),
        Hub(name: "东京", longitude: 139.6917, latitude: 35.6895),
        Hub(name: "首尔", longitude: 126.9780, latitude: 37.5665),
        Hub(name: "新加坡", longitude: 103.8198, latitude: 1.3521),
        Hub(name: "曼谷", longitude: 100.5018, latitude: 13.7563),
        Hub(name: "悉尼", longitude: 151.2093, latitude: -33.8688),
        Hub(name: "奥克兰", longitude: 174.7633, latitude: -36.8485),
        Hub(name: "迪拜", longitude: 55.2708, latitude: 25.2048),
        Hub(name: "伊斯坦布尔", longitude: 28.9784, latitude: 41.0082),
        Hub(name: "雅典", longitude: 23.7275, latitude: 37.9838),
        Hub(name: "罗马", longitude: 12.4964, latitude: 41.9028),
        Hub(name: "巴黎", longitude: 2.3522, latitude: 48.8566),
        Hub(name: "伦敦", longitude: -0.1276, latitude: 51.5072),
        Hub(name: "巴塞罗那", longitude: 2.1734, latitude: 41.3851),
        Hub(name: "雷克雅未克", longitude: -21.9426, latitude: 64.1466),
        Hub(name: "开普敦", longitude: 18.4241, latitude: -33.9249),
        Hub(name: "内罗毕", longitude: 36.8219, latitude: -1.2921),
        Hub(name: "开罗", longitude: 31.2357, latitude: 30.0444),
        Hub(name: "纽约", longitude: -74.0060, latitude: 40.7128),
        Hub(name: "洛杉矶", longitude: -118.2437, latitude: 34.0522),
        Hub(name: "旧金山", longitude: -122.4194, latitude: 37.7749),
        Hub(name: "温哥华", longitude: -123.1207, latitude: 49.2827),
        Hub(name: "墨西哥城", longitude: -99.1332, latitude: 19.4326),
        Hub(name: "里约热内卢", longitude: -43.1729, latitude: -22.9068),
        Hub(name: "布宜诺斯艾利斯", longitude: -58.3816, latitude: -34.6037),
        Hub(name: "利马", longitude: -77.0428, latitude: -12.0464),
    ]

    static func clusters(count: Int = 1_000) -> [WorldMapCluster] {
        guard count > 0 else { return [] }
        var generator = Generator(state: 0x494D_4147_4541_4C4C)
        return (0 ..< count).map { index in
            let hub = hubs[index % hubs.count]
            let distance = pow(generator.nextUnit(), 2.4) * 8.5
            let angle = generator.nextUnit() * .pi * 2
            let latitude = min(78, max(-78, hub.latitude + sin(angle) * distance))
            let longitudeScale = max(0.28, cos(latitude * .pi / 180))
            let rawLongitude = hub.longitude + cos(angle) * distance / longitudeScale
            let longitude = ((rawLongitude + 540).truncatingRemainder(dividingBy: 360)) - 180
            let photoCount = 8 + Int(pow(generator.nextUnit(), 2.15) * 2_800)
            let gpsRatio = 0.58 + generator.nextUnit() * 0.38
            let gpsCount = min(photoCount, Int(Double(photoCount) * gpsRatio))
            return WorldMapCluster(
                id: String(format: "demo-%04d", index),
                longitude: longitude,
                latitude: latitude,
                photoCount: photoCount,
                gpsCount: gpsCount,
                tagCount: photoCount - gpsCount,
                displayName: index < hubs.count ? hub.name : "\(hub.name)周边"
            )
        }
    }
}

private struct WorldMapClusterPayload: Encodable {
    let revision: Int
    let clusters: [WorldMapCluster]
}

private enum WorldMapResource {
    static func directoryURL(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("WorldMap", isDirectory: true)
    }
}

@MainActor
struct WorldMapWorkspaceView: View {
    private enum Palette {
        static let paper = Color(red: 0.957, green: 0.945, blue: 0.922)
        static let surface = Color(red: 0.988, green: 0.980, blue: 0.965)
        static let ink = Color(red: 0.235, green: 0.270, blue: 0.275)
        static let secondaryInk = Color(red: 0.390, green: 0.435, blue: 0.435)
        static let border = Color(red: 0.690, green: 0.735, blue: 0.710)
        static let sage = Color(red: 0.590, green: 0.690, blue: 0.625)
        static let mistBlue = Color(red: 0.576, green: 0.749, blue: 0.816)
        static let lavender = Color(red: 0.714, green: 0.659, blue: 0.788)
        static let peach = Color(red: 0.859, green: 0.686, blue: 0.616)
        static let butter = Color(red: 0.847, green: 0.788, blue: 0.561)
        static let rose = Color(red: 0.780, green: 0.545, blue: 0.545)
    }

    private enum RendererState: Equatable {
        case starting
        case ready(webGL2Available: Bool)
        case failed(String)
    }

    private enum CatalogState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private enum ClusterSelectionState: Equatable {
        case idle
        case loading
        case loaded(WorldMapCatalogSelection)
        case failed(String)
    }

    let model: LibraryWorkspaceModel
    @Binding var navigationState: WorldMapNavigationState
    let onBrowseCluster: (WorldMapGalleryScope) -> Void
    @State private var rendererState: RendererState = .starting
    @State private var catalogState: CatalogState = .loading
    @State private var catalogSnapshot = WorldMapCatalogSnapshot.empty
    @State private var clusters: [WorldMapCluster] = []
    @State private var catalogClustersByID: [String: WorldMapCatalogCluster] = [:]
    @State private var selectedClusterID: String?
    @State private var clusterSelectionState: ClusterSelectionState = .idle
    @State private var selectionRequestID = UUID()
    @State private var previewAsset: WorldMapCatalogAsset?
    @State private var viewport: WorldMapViewport?
    @State private var catalogRequestID = UUID()
    @State private var showPlaceResolution = false
    @State private var showLocationBackfill = false

    init(
        model: LibraryWorkspaceModel,
        navigationState: Binding<WorldMapNavigationState>,
        onBrowseCluster: @escaping (WorldMapGalleryScope) -> Void
    ) {
        self.model = model
        _navigationState = navigationState
        self.onBrowseCluster = onBrowseCluster
        _selectedClusterID = State(initialValue: navigationState.wrappedValue.selectedClusterID)
        _viewport = State(initialValue: navigationState.wrappedValue.viewport)
    }

    private var selectedCluster: WorldMapCluster? {
        guard let selectedClusterID else { return nil }
        return clusters.first { $0.id == selectedClusterID }
    }

    private var totalPhotoCount: Int {
        catalogSnapshot.locatedPhotoCount
    }

    var body: some View {
        ZStack {
            Palette.paper
                .ignoresSafeArea()

            WorldMapWebView(
                clusters: clusters,
                initialViewport: navigationState.viewport,
                selectedClusterID: selectedClusterID,
                onEvent: receive
            )
                .ignoresSafeArea()

            LinearGradient(
                colors: [Palette.paper.opacity(0.52), .clear, Palette.paper.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                heroOverlay
                Spacer()
                footerOverlay
            }
            .padding(22)

            if case let .failed(message) = rendererState {
                rendererFailure(message)
            }
        }
        .accessibilityIdentifier("worldMapWorkspace")
        .task {
            await loadCatalog(query: navigationState.viewport?.catalogQuery ?? .global)
        }
        .sheet(item: $previewAsset) { asset in
            WorldMapPhotoPreview(asset: asset, model: model)
        }
        .sheet(isPresented: $showPlaceResolution) {
            WorldMapPlaceResolutionSheet(model: model) {
                Task {
                    await loadCatalog(query: viewport?.catalogQuery ?? .global)
                }
            }
        }
        .sheet(isPresented: $showLocationBackfill, onDismiss: {
            Task {
                await loadCatalog(query: viewport?.catalogQuery ?? .global)
            }
        }) {
            WorldMapLocationBackfillSheet(model: model)
        }
    }

    private var heroOverlay: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                heroCopy
                Spacer(minLength: 20)
                locationBackfillButton
                placeResolutionButton
                metric(value: clusters.count.formatted(), label: "视口建筑", tint: Palette.mistBlue)
                metric(value: compact(totalPhotoCount), label: "已定位", tint: Palette.sage)
                metric(
                    value: compact(catalogSnapshot.unlocatedPhotoCount),
                    label: "待定位",
                    tint: Palette.peach
                )
                metric(value: rendererLabel, label: "渲染核心", tint: Palette.lavender)
            }
            VStack(alignment: .leading, spacing: 12) {
                heroCopy
                HStack(spacing: 9) {
                    locationBackfillButton
                    placeResolutionButton
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(Palette.surface.opacity(0.93), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Palette.mistBlue.opacity(0.72),
                            Palette.sage.opacity(0.42),
                            Palette.peach.opacity(0.62),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .shadow(color: Palette.ink.opacity(0.09), radius: 24, y: 9)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text("PHOTO ATLAS / LIVE CATALOG")
                    .font(.caption2.monospaced().weight(.bold))
                    .tracking(1.6)
                    .foregroundStyle(Palette.sage)
            }
            Text("你的照片，长成一座世界。")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
            Text("拖拽探索 · 双指缩放 · ⌃拖拽旋转与俯仰 · 点击照片塔")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    private var placeResolutionButton: some View {
        Button {
            showPlaceResolution = true
        } label: {
            Label("补全地点", systemImage: "mappin.and.ellipse")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.peach.opacity(0.18), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Palette.peach.opacity(0.46))
                }
        }
        .buttonStyle(.plain)
        .help("从已确认标签中选择城市或景区，并在需要时确认同名地点")
        .accessibilityIdentifier("worldMapPlaceResolutionButton")
    }

    private var locationBackfillButton: some View {
        Button {
            showLocationBackfill = true
        } label: {
            Label("更新照片位置", systemImage: "location.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.mistBlue.opacity(0.17), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Palette.mistBlue.opacity(0.46))
                }
        }
        .buttonStyle(.plain)
        .help("按来源显式扫描旧照片的位置元数据；打开面板本身不会开始扫描")
        .accessibilityIdentifier("worldMapLocationBackfillButton")
    }

    private var footerOverlay: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if let cluster = selectedCluster {
                Spacer(minLength: 0)
                selectedClusterCard(cluster)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                footerLegend
                Spacer()
                Text(footerPrompt)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Palette.surface.opacity(0.91), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Palette.border.opacity(0.48))
                    }
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: selectedClusterID)
    }

    private var footerLegend: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("照片越多，建筑越高")
                .font(.caption2.monospaced().weight(.bold))
                .tracking(1.3)
                .foregroundStyle(Palette.secondaryInk)
            HStack(spacing: 7) {
                legend(color: Palette.mistBlue, title: "少")
                legend(color: Palette.lavender, title: "中")
                legend(color: Palette.peach, title: "多")
                legend(color: Palette.butter, title: "密集")
            }
            if let viewport {
                Text(
                    "ZOOM \(viewport.zoom.formatted(.number.precision(.fractionLength(1))))  "
                        + "PITCH \(Int(viewport.pitch))°  BEARING \(Int(viewport.bearing))°"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Palette.secondaryInk.opacity(0.78))
            }
        }
        .padding(14)
        .background(Palette.surface.opacity(0.91), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Palette.border.opacity(0.52))
        }
    }

    private func selectedClusterCard(_ cluster: WorldMapCluster) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(cluster.displayName)
                    .font(.headline)
                Spacer(minLength: 16)
                Button {
                    clearSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondaryInk)
                .accessibilityLabel("关闭地点详情")
            }
            Text("\(cluster.photoCount.formatted()) 张照片")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.mistBlue)
            HStack(spacing: 12) {
                Label("GPS \(cluster.gpsCount.formatted())", systemImage: "location.fill")
                Label("标签 \(cluster.tagCount.formatted())", systemImage: "tag.fill")
            }
            .font(.caption)
            .foregroundStyle(Palette.secondaryInk)
            Text("GPS 始终优先；已确认的城市或景区标签只为无 GPS 照片补全位置。")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            if case let .loaded(selection) = clusterSelectionState,
               selection.totalPhotoCount > 0
            {
                Button {
                    openClusterInGallery(clusterID: cluster.id)
                } label: {
                    Label(
                        "在图库中查看全部 \(selection.totalPhotoCount.formatted()) 张",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Palette.mistBlue.opacity(0.18), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Palette.mistBlue.opacity(0.52))
                    }
                }
                .buttonStyle(.plain)
                .help("使用这座照片塔的精确地点范围打开现有图库")
                .accessibilityIdentifier("worldMapBrowseClusterButton")
            }
            clusterPhotoStrip
        }
        .padding(15)
        .frame(minWidth: 320, idealWidth: 460, maxWidth: 460, alignment: .leading)
        .foregroundStyle(Palette.ink)
        .background(Palette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Palette.mistBlue.opacity(0.58))
        }
        .shadow(color: Palette.ink.opacity(0.10), radius: 22, y: 8)
    }

    @ViewBuilder
    private var clusterPhotoStrip: some View {
        Divider()
            .overlay(Palette.border.opacity(0.45))

        switch clusterSelectionState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在取回这座照片塔里的照片…")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            .frame(height: 76)
        case let .loaded(selection) where selection.assets.isEmpty:
            Label("这座照片塔目前没有可预览照片", systemImage: "photo.on.rectangle.angled")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
                .frame(height: 76)
        case let .loaded(selection):
            VStack(alignment: .leading, spacing: 7) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(selection.assets) { asset in
                            Button {
                                previewAsset = asset
                            } label: {
                                WorldMapPhotoThumbnail(asset: asset, model: model)
                            }
                            .buttonStyle(.plain)
                            .help(asset.fileName ?? "打开照片预览")
                            .accessibilityLabel(asset.fileName ?? "打开照片预览")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 78)

                Text(selectionSummary(selection))
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk.opacity(0.80))
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Palette.rose)
                .frame(height: 76)
        }
    }

    private func metric(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(.system(.headline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 78, alignment: .trailing)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 20, height: 5)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    private func rendererFailure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("地图渲染器未启动", systemImage: "globe.badge.chevron.backward")
        } description: {
            Text(message)
        }
        .padding(26)
        .frame(maxWidth: 460)
        .foregroundStyle(Palette.ink)
        .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Palette.rose.opacity(0.36))
        }
    }

    private var rendererLabel: String {
        switch rendererState {
        case .starting: "启动中"
        case let .ready(webGL2Available): webGL2Available ? "WEBGL2" : "兼容模式"
        case .failed: "离线"
        }
    }

    private var footerPrompt: String {
        switch catalogState {
        case .loading:
            "正在聚合目录库位置…"
        case .loaded where clusters.isEmpty:
            "当前视口暂无已定位照片；重新扫描来源可回填 GPS"
        case .loaded:
            "选择一座照片建筑查看构成"
        case let .failed(message):
            "位置数据载入失败：\(message)"
        }
    }

    private var statusColor: Color {
        switch rendererState {
        case .starting: Palette.butter
        case .ready: Palette.sage
        case .failed: Palette.rose
        }
    }

    private func receive(_ event: WorldMapBridgeEvent) {
        switch event {
        case let .ready(webGL2Available):
            rendererState = .ready(webGL2Available: webGL2Available)
        case let .cameraChanged(newViewport):
            viewport = newViewport
            navigationState.viewport = newViewport
            Task {
                await loadCatalog(query: newViewport.catalogQuery)
            }
        case let .clusterClicked(id):
            guard clusters.contains(where: { $0.id == id }) else { return }
            selectedClusterID = id
            navigationState.selectedClusterID = id
            clusterSelectionState = .loading
            Task {
                await loadSelection(clusterID: id)
            }
        case let .renderError(message):
            rendererState = .failed(message)
        }
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func loadCatalog(query: WorldMapCatalogQuery) async {
        let requestID = UUID()
        catalogRequestID = requestID
        catalogState = .loading
        do {
            let snapshot = try await model.fetchWorldMapSnapshot(query: query)
            guard catalogRequestID == requestID else { return }
            catalogSnapshot = snapshot
            catalogClustersByID = Dictionary(
                uniqueKeysWithValues: snapshot.clusters.map { ($0.id, $0) }
            )
            clusters = snapshot.clusters.map {
                WorldMapCluster(
                    id: $0.id,
                    longitude: $0.longitude,
                    latitude: $0.latitude,
                    photoCount: $0.photoCount,
                    gpsCount: $0.gpsCount,
                    tagCount: $0.tagCount,
                    displayName: $0.displayName
                )
            }
            if let selectedClusterID,
               !clusters.contains(where: { $0.id == selectedClusterID })
            {
                clearSelection()
            }
            catalogState = .loaded
            if let selectedClusterID,
               clusters.contains(where: { $0.id == selectedClusterID }),
               case .idle = clusterSelectionState
            {
                clusterSelectionState = .loading
                Task {
                    await loadSelection(clusterID: selectedClusterID)
                }
            }
        } catch {
            guard catalogRequestID == requestID else { return }
            catalogState = .failed("目录库查询不可用")
        }
    }

    private func loadSelection(clusterID: String) async {
        guard let cluster = catalogClustersByID[clusterID] else {
            guard selectedClusterID == clusterID else { return }
            clusterSelectionState = .failed("地点范围已变化，请重新选择照片塔")
            return
        }
        let requestID = UUID()
        selectionRequestID = requestID
        do {
            let selection = try await model.fetchWorldMapSelection(
                query: cluster.selectionQuery
            )
            guard selectionRequestID == requestID,
                  selectedClusterID == clusterID
            else {
                return
            }
            clusterSelectionState = .loaded(selection)
        } catch {
            guard selectionRequestID == requestID,
                  selectedClusterID == clusterID
            else {
                return
            }
            clusterSelectionState = .failed("照片预览载入失败")
        }
    }

    private func clearSelection() {
        selectionRequestID = UUID()
        selectedClusterID = nil
        navigationState.selectedClusterID = nil
        clusterSelectionState = .idle
        previewAsset = nil
    }

    private func openClusterInGallery(clusterID: String) {
        guard let cluster = catalogClustersByID[clusterID] else { return }
        navigationState.selectedClusterID = clusterID
        onBrowseCluster(
            WorldMapGalleryScope(
                clusterID: clusterID,
                displayName: cluster.displayName,
                photoCount: cluster.photoCount,
                selectionQuery: cluster.selectionQuery
            )
        )
    }

    private func selectionSummary(_ selection: WorldMapCatalogSelection) -> String {
        if selection.isTruncated {
            return "按拍摄时间显示最近 \(selection.assets.count) 张，共 \(selection.totalPhotoCount) 张"
        }
        return "已显示这座照片塔的 \(selection.totalPhotoCount) 张照片"
    }
}

@MainActor
private struct WorldMapLocationBackfillSheet: View {
    private enum Palette {
        static let paper = Color(red: 0.957, green: 0.945, blue: 0.922)
        static let surface = Color(red: 0.988, green: 0.980, blue: 0.965)
        static let ink = Color(red: 0.235, green: 0.270, blue: 0.275)
        static let secondaryInk = Color(red: 0.390, green: 0.435, blue: 0.435)
        static let border = Color(red: 0.690, green: 0.735, blue: 0.710)
        static let sage = Color(red: 0.590, green: 0.690, blue: 0.625)
        static let mistBlue = Color(red: 0.576, green: 0.749, blue: 0.816)
        static let lavender = Color(red: 0.714, green: 0.659, blue: 0.788)
        static let peach = Color(red: 0.859, green: 0.686, blue: 0.616)
        static let rose = Color(red: 0.780, green: 0.545, blue: 0.545)
        static let butter = Color(red: 0.847, green: 0.788, blue: 0.561)
    }

    let model: LibraryWorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [WorldMapLocationBackfillSnapshot] = []
    @State private var busySourceIDs = Set<UUID>()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.border.opacity(0.42))
                content
            }
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 520, idealHeight: 650)
        .task {
            await monitorSnapshots()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(Palette.mistBlue.opacity(0.18))
                Image(systemName: "location.viewfinder")
                    .font(.title2)
                    .foregroundStyle(Palette.mistBlue)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("把旧照片的位置带回地图")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("选择一个来源开始；不会因为打开地图或此面板自动扫描。")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.sage)
        }
        .padding(22)
        .background(Palette.surface.opacity(0.88))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读取本地位置目录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshots.isEmpty {
            ContentUnavailableView {
                Label("还没有照片来源", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("连接文件夹或 Apple Photos 后，可在这里显式更新旧照片的位置。")
            }
            .foregroundStyle(Palette.ink)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    safetyNote
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.rose)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(
                                Palette.rose.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                    ForEach(snapshots) { snapshot in
                        sourceCard(snapshot)
                    }
                }
                .padding(20)
            }
        }
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(Palette.peach)
            Text("开始后只读取所选来源的图片元数据：文件夹通过 ImageIO 检查内嵌 GPS，Apple Photos 通过正常授权的 PhotoKit 读取位置。不会移动、重命名、覆盖或写回原照片。")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.peach.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Palette.peach.opacity(0.27))
        }
    }

    private func sourceCard(_ snapshot: WorldMapLocationBackfillSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: snapshot.sourceKind == .photos
                    ? "photo.on.rectangle.angled"
                    : "externaldrive.fill")
                    .font(.title3)
                    .foregroundStyle(snapshot.sourceKind == .photos
                        ? Palette.lavender
                        : Palette.sage)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.sourceDisplayName)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text(snapshot.sourceKind == .photos ? "APPLE PHOTOS" : "文件夹来源")
                        .font(.caption2.monospaced().weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(Palette.secondaryInk)
                }
                Spacer()
                phaseBadge(snapshot.phase)
            }

            ProgressView(value: snapshot.coverageFraction)
                .tint(coverageTint(snapshot.phase))

            HStack(spacing: 18) {
                countMetric(
                    value: snapshot.inspectedPhotoCount,
                    total: snapshot.totalPhotoCount,
                    label: "已检查"
                )
                countMetric(value: snapshot.locatedPhotoCount, label: "已定位")
                countMetric(
                    value: max(0, snapshot.inspectedPhotoCount - snapshot.locatedPhotoCount),
                    label: "无坐标"
                )
                Spacer()
                actionButton(snapshot)
            }

            if let scanProgress = snapshot.scanProgress {
                HStack(spacing: 7) {
                    if snapshot.phase == .running || snapshot.phase == .cancelling {
                        ProgressView().controlSize(.small)
                    }
                    Text(scanProgressLabel(scanProgress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Palette.border.opacity(0.43))
        }
        .shadow(color: Palette.ink.opacity(0.045), radius: 12, y: 4)
        .accessibilityIdentifier("worldMapLocationBackfillSourceCard")
    }

    private func countMetric(value: Int, total: Int? = nil, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(total.map { "\(value.formatted()) / \($0.formatted())" } ?? value.formatted())
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    @ViewBuilder
    private func actionButton(_ snapshot: WorldMapLocationBackfillSnapshot) -> some View {
        if snapshot.canCancel {
            Button("取消") {
                cancel(snapshot)
            }
            .buttonStyle(.bordered)
            .tint(Palette.rose)
            .disabled(busySourceIDs.contains(snapshot.sourceID))
        } else if snapshot.canStart {
            Button(actionTitle(snapshot.phase)) {
                start(snapshot)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.mistBlue)
            .disabled(busySourceIDs.contains(snapshot.sourceID))
        } else if snapshot.phase == .cancelling {
            Text("正在取消…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        } else if snapshot.phase == .completed {
            Label("目录已更新", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.sage)
        } else if snapshot.phase == .unavailable {
            Text("请先恢复来源访问")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryInk)
        }
    }

    private func phaseBadge(_ phase: WorldMapLocationBackfillPhase) -> some View {
        let presentation: (String, Color) = switch phase {
        case .ready: ("待检查", Palette.mistBlue)
        case .queued: ("等待中", Palette.butter)
        case .running: ("检查中", Palette.mistBlue)
        case .cancelling: ("取消中", Palette.peach)
        case .retryableFailed: ("可重试", Palette.peach)
        case .completed: ("已完成", Palette.sage)
        case .cancelled: ("已取消", Palette.border)
        case .terminalFailed: ("检查失败", Palette.rose)
        case .unavailable: ("来源不可用", Palette.border)
        }
        return Text(presentation.0)
            .font(.caption2.weight(.bold))
            .foregroundStyle(presentation.1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(presentation.1.opacity(0.11), in: Capsule())
    }

    private func coverageTint(_ phase: WorldMapLocationBackfillPhase) -> Color {
        switch phase {
        case .completed: Palette.sage
        case .terminalFailed: Palette.rose
        case .cancelled, .unavailable: Palette.border
        case .ready, .queued, .running, .cancelling, .retryableFailed: Palette.mistBlue
        }
    }

    private func actionTitle(_ phase: WorldMapLocationBackfillPhase) -> String {
        switch phase {
        case .ready: "开始检查"
        case .retryableFailed, .cancelled, .terminalFailed: "重试"
        case .queued, .running, .cancelling, .completed, .unavailable: "开始检查"
        }
    }

    private func scanProgressLabel(_ progress: JobProgress) -> String {
        if let total = progress.total {
            return "来源扫描 \(progress.completed.formatted()) / \(total.formatted())"
        }
        return "来源扫描已处理 \(progress.completed.formatted()) 项"
    }

    private func monitorSnapshots() async {
        while !Task.isCancelled {
            await loadSnapshots()
            do {
                // Coverage counts scan the eligible catalog, so keep the UI live
                // without turning a million-row status query into a tight loop.
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
        }
    }

    private func loadSnapshots() async {
        do {
            snapshots = try await model.fetchWorldMapLocationBackfillSnapshots()
            errorMessage = nil
        } catch {
            errorMessage = "位置目录状态读取失败，请稍后重试。"
        }
        isLoading = false
    }

    private func start(_ snapshot: WorldMapLocationBackfillSnapshot) {
        guard busySourceIDs.insert(snapshot.sourceID).inserted else { return }
        errorMessage = nil
        Task {
            defer { busySourceIDs.remove(snapshot.sourceID) }
            do {
                try await model.startWorldMapLocationBackfill(sourceID: snapshot.sourceID)
                await loadSnapshots()
            } catch {
                errorMessage = "“\(snapshot.sourceDisplayName)”的位置检查未能开始。"
            }
        }
    }

    private func cancel(_ snapshot: WorldMapLocationBackfillSnapshot) {
        guard busySourceIDs.insert(snapshot.sourceID).inserted else { return }
        errorMessage = nil
        Task {
            defer { busySourceIDs.remove(snapshot.sourceID) }
            do {
                try await model.cancelWorldMapLocationBackfill(sourceID: snapshot.sourceID)
                await loadSnapshots()
            } catch {
                errorMessage = "“\(snapshot.sourceDisplayName)”的取消请求未能提交。"
            }
        }
    }
}

@MainActor
private struct WorldMapPlaceResolutionSheet: View {
    private enum Palette {
        static let paper = Color(red: 0.957, green: 0.945, blue: 0.922)
        static let surface = Color(red: 0.988, green: 0.980, blue: 0.965)
        static let ink = Color(red: 0.235, green: 0.270, blue: 0.275)
        static let secondaryInk = Color(red: 0.390, green: 0.435, blue: 0.435)
        static let border = Color(red: 0.690, green: 0.735, blue: 0.710)
        static let sage = Color(red: 0.590, green: 0.690, blue: 0.625)
        static let mistBlue = Color(red: 0.576, green: 0.749, blue: 0.816)
        static let lavender = Color(red: 0.714, green: 0.659, blue: 0.788)
        static let peach = Color(red: 0.859, green: 0.686, blue: 0.616)
        static let rose = Color(red: 0.780, green: 0.545, blue: 0.545)
    }

    let model: LibraryWorkspaceModel
    let onLocationChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [WorldMapPlaceTagResolution] = []
    @State private var busyTagIDs = Set<UUID>()
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.border.opacity(0.45))
                content
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 680)
        .task {
            await loadItems()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(Palette.peach.opacity(0.20))
                Image(systemName: "map.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.peach)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text("把地点标签放回地图")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("只列出至少关联一张已确认照片的标签；“地点与场景”分组会排在最前。")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Palette.sage)
        }
        .padding(22)
        .background(Palette.surface.opacity(0.88))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在读取地点标签缓存…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("还没有可解析的标签", systemImage: "tag.slash")
            } description: {
                Text("先给照片确认城市、景区或国家标签，再回到这里补全地图位置。")
            }
            .foregroundStyle(Palette.ink)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    privacyNote
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.rose)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(Palette.rose.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(items) { item in
                        resolutionCard(item)
                    }
                }
                .padding(20)
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .foregroundStyle(Palette.mistBlue)
            Text("打开此面板只读取本地缓存。只有点击某个标签的“识别地点”后，才会用该标签文字向 Apple 地图发起一次搜索；照片、路径和资产标识不会发送。")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.mistBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Palette.mistBlue.opacity(0.28))
        }
    }

    private func resolutionCard(_ item: WorldMapPlaceTagResolution) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.tagName)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(item.groupName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.lavender.opacity(0.13), in: Capsule())
                Spacer()
                Text("\(item.acceptedPhotoCount.formatted()) 张")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.secondaryInk)
                statusBadge(item.status)
            }

            switch item.status {
            case .unresolved, .failed:
                HStack(spacing: 12) {
                    Text(item.status == .failed ? "上次没有找到匹配地点，可再次尝试。" : "尚未请求地点搜索。")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryInk)
                    Spacer()
                    Button {
                        resolve(item)
                    } label: {
                        if busyTagIDs.contains(item.tagID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("识别地点", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.mistBlue)
                    .disabled(busyTagIDs.contains(item.tagID))
                }
            case .ambiguous:
                Text("找到多个同名地点，请确认照片实际对应哪一个：")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
                ForEach(item.candidates) { candidate in
                    Button {
                        confirm(item, candidate: candidate)
                    } label: {
                        candidateRow(candidate, isBusy: busyTagIDs.contains(item.tagID))
                    }
                    .buttonStyle(.plain)
                    .disabled(busyTagIDs.contains(item.tagID))
                }
            case .resolved:
                if let candidate = item.candidates.first(where: { $0.placeID == item.confirmedPlaceID }) {
                    candidateRow(candidate, isBusy: false)
                } else {
                    Label("地点已经确认并写入地图目录。", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.sage)
                }
            case .ignored:
                Text("这个标签已标记为非地点，不会参与地图定位。")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Palette.border.opacity(0.44))
        }
        .shadow(color: Palette.ink.opacity(0.045), radius: 12, y: 4)
    }

    private func candidateRow(
        _ candidate: WorldMapPlaceCandidate,
        isBusy: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.kind == .poi ? "mappin.circle.fill" : "building.2.fill")
                .font(.title3)
                .foregroundStyle(Palette.peach)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(candidate.subtitle ?? coordinateLabel(candidate))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Palette.sage)
            }
        }
        .padding(12)
        .background(Palette.sage.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Palette.sage.opacity(0.24))
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func statusBadge(_ status: WorldMapPlaceBindingStatus) -> some View {
        let presentation: (String, Color) = switch status {
        case .unresolved: ("未识别", Palette.border)
        case .resolved: ("已确认", Palette.sage)
        case .ambiguous: ("待选择", Palette.peach)
        case .ignored: ("已忽略", Palette.border)
        case .failed: ("未找到", Palette.rose)
        }
        return Text(presentation.0)
            .font(.caption2.weight(.bold))
            .foregroundStyle(presentation.1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(presentation.1.opacity(0.11), in: Capsule())
    }

    private func coordinateLabel(_ candidate: WorldMapPlaceCandidate) -> String {
        String(format: "%.3f°, %.3f°", candidate.latitude, candidate.longitude)
    }

    private func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await model.fetchWorldMapPlaceTagResolutions()
        } catch {
            errorMessage = "地点标签缓存读取失败。"
        }
    }

    private func resolve(_ item: WorldMapPlaceTagResolution) {
        guard busyTagIDs.insert(item.tagID).inserted else { return }
        errorMessage = nil
        Task {
            defer { busyTagIDs.remove(item.tagID) }
            do {
                let updated = try await model.resolveWorldMapPlaceTag(tagID: item.tagID)
                replace(updated)
                if updated.status == .resolved {
                    onLocationChanged()
                }
            } catch {
                errorMessage = "“\(item.tagName)”的地点搜索失败，请稍后重试。"
            }
        }
    }

    private func confirm(
        _ item: WorldMapPlaceTagResolution,
        candidate: WorldMapPlaceCandidate
    ) {
        guard busyTagIDs.insert(item.tagID).inserted else { return }
        errorMessage = nil
        Task {
            defer { busyTagIDs.remove(item.tagID) }
            do {
                let updated = try await model.confirmWorldMapPlaceCandidate(
                    tagID: item.tagID,
                    placeID: candidate.placeID
                )
                replace(updated)
                onLocationChanged()
            } catch {
                errorMessage = "地点候选已变化，请重新打开面板后再试。"
            }
        }
    }

    private func replace(_ item: WorldMapPlaceTagResolution) {
        guard let index = items.firstIndex(where: { $0.tagID == item.tagID }) else { return }
        items[index] = item
    }
}

@MainActor
private struct WorldMapPhotoThumbnail: View {
    let asset: WorldMapCatalogAsset
    let model: LibraryWorkspaceModel

    @State private var image: NSImage?
    @State private var loadFinished = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(red: 0.925, green: 0.925, blue: 0.890))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loadFinished {
                Image(systemName: "photo")
                    .foregroundStyle(Color.secondary.opacity(0.72))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.white.opacity(0.72))
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .task(id: asset.assetID) {
            defer { loadFinished = true }
            guard let data = await model.thumbnailData(assetID: asset.assetID) else { return }
            image = NSImage(data: data)
        }
    }
}

@MainActor
private struct WorldMapPhotoPreview: View {
    let asset: WorldMapCatalogAsset
    let model: LibraryWorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var loadFinished = false

    var body: some View {
        ZStack {
            Color(red: 0.957, green: 0.945, blue: 0.922)
                .ignoresSafeArea()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(28)
            } else if loadFinished {
                ContentUnavailableView(
                    "预览不可用",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("照片可能仅在云端，或当前来源暂时不可访问。")
                )
            } else {
                ProgressView("正在载入照片预览…")
            }

            VStack {
                HStack {
                    Text(asset.fileName ?? "照片预览")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .accessibilityLabel("关闭照片预览")
                }
                .padding(18)
                .background(.ultraThinMaterial)
                Spacer()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task(id: asset.assetID) {
            defer { loadFinished = true }
            guard let data = await model.previewData(assetID: asset.assetID) else { return }
            image = NSImage(data: data)
        }
    }
}

@MainActor
private struct WorldMapWebView: NSViewRepresentable {
    let clusters: [WorldMapCluster]
    let initialViewport: WorldMapViewport?
    let selectedClusterID: String?
    let onEvent: (WorldMapBridgeEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            clusters: clusters,
            selectedClusterID: selectedClusterID,
            onEvent: onEvent
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageHandlerName
        )
        if let initialViewport,
           let data = try? JSONEncoder().encode(initialViewport),
           let json = String(data: data, encoding: .utf8)
        {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: "globalThis.ImageAllWorldMapInitialCamera = \(json);",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
#if DEBUG
        webView.isInspectable = true
#endif
        context.coordinator.webView = webView

        guard let directoryURL = WorldMapResource.directoryURL(),
              FileManager.default.fileExists(atPath: directoryURL.path),
              FileManager.default.fileExists(
                  atPath: directoryURL.appendingPathComponent("index.html").path
              )
        else {
            onEvent(.renderError(message: "App 包内缺少 WorldMap 本地资源。"))
            return webView
        }
        webView.loadFileURL(
            directoryURL.appendingPathComponent("index.html"),
            allowingReadAccessTo: directoryURL
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            clusters: clusters,
            selectedClusterID: selectedClusterID,
            on: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "worldMapBridge"

        weak var webView: WKWebView?
        private var clusters: [WorldMapCluster]
        private var selectedClusterID: String?
        private let onEvent: (WorldMapBridgeEvent) -> Void
        private var isReady = false
        private var revision = 0

        init(
            clusters: [WorldMapCluster],
            selectedClusterID: String?,
            onEvent: @escaping (WorldMapBridgeEvent) -> Void
        ) {
            self.clusters = clusters
            self.selectedClusterID = selectedClusterID
            self.onEvent = onEvent
        }

        func update(
            clusters: [WorldMapCluster],
            selectedClusterID: String?,
            on webView: WKWebView
        ) {
            guard clusters != self.clusters || selectedClusterID != self.selectedClusterID else {
                return
            }
            self.clusters = clusters
            self.selectedClusterID = selectedClusterID
            sendClusters(to: webView)
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageHandlerName,
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body),
                  let event = try? WorldMapBridgeDecoder.decode(data: data)
            else {
                return
            }
            if case .ready = event {
                isReady = true
                if let webView {
                    sendClusters(to: webView)
                }
            }
            onEvent(event)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            onEvent(.renderError(message: "本地地图页面载入失败：\(error.localizedDescription)"))
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation!,
            withError error: Error
        ) {
            onEvent(.renderError(message: "本地地图页面无法打开：\(error.localizedDescription)"))
        }

        private func sendClusters(to webView: WKWebView) {
            guard isReady else { return }
            revision &+= 1
            let payload = WorldMapClusterPayload(revision: revision, clusters: clusters)
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8),
                  let selectionData = try? JSONEncoder().encode(selectedClusterID),
                  let selectionJSON = String(data: selectionData, encoding: .utf8)
            else {
                onEvent(.renderError(message: "地图聚合数据编码失败。"))
                return
            }
            webView.evaluateJavaScript(
                """
                window.ImageAllWorldMap.updateClusters(\(json));
                window.ImageAllWorldMap.restoreSelection(\(selectionJSON));
                """
            ) {
                [onEvent] _, error in
                if let error {
                    onEvent(.renderError(message: "地图数据桥接失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}
