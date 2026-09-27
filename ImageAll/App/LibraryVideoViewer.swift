import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AVKit
import SwiftUI

/// One foreground player, separate from the muted grid-hover player. A stopped or
/// superseded request can never attach its late resource to the current selection.
@MainActor
final class LibraryVideoViewingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    struct Identity: Hashable {
        let assetID: UUID
        let revision: Int
    }

    let player = AVPlayer()
    @Published private(set) var state: State = .idle
    @Published private(set) var speed: Float = 1
    private(set) var identity: Identity?
    private var requestID: UUID?
    private var resource: LibraryVideoPlaybackResource?
    private var itemObservation: NSKeyValueObservation?

    func load(
        identity: Identity,
        prepare: @MainActor () async throws -> LibraryVideoPlaybackResource
    ) async {
        stop()
        let request = UUID()
        requestID = request
        self.identity = identity
        state = .loading
        do {
            let prepared = try await prepare()
            guard requestID == request, !Task.isCancelled else {
                prepared.release()
                if requestID == request { stop() }
                return
            }
            resource = prepared
            let asset = AVURLAsset(url: prepared.url)
            let playable = try await asset.load(.isPlayable)
            try Task.checkCancellation()
            guard requestID == request else { return }
            guard playable else { throw LibraryOriginalAssetOpenError.previewUnavailable }
            let item = AVPlayerItem(asset: asset)
            player.defaultRate = speed
            player.replaceCurrentItem(with: item)
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    self?.fail(request: request, message: "此视频无法解码，请使用系统播放器检查文件。")
                }
            }
            state = .ready
        } catch {
            guard requestID == request else { return }
            if Task.isCancelled || error is CancellationError {
                stop()
            } else {
                fail(request: request, message: Self.message(for: error))
            }
        }
    }

    func togglePlayback() {
        guard state == .ready else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func setSpeed(_ value: Float) {
        guard [Float(0.5), 1, 1.5, 2].contains(value) else { return }
        speed = value
        player.defaultRate = value
        if player.rate != 0 { player.rate = value }
    }

    func stop(ifMatching expected: Identity? = nil) {
        if let expected, identity != expected { return }
        requestID = nil
        identity = nil
        itemObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        resource?.release()
        resource = nil
        state = .idle
    }

    private func fail(request: UUID, message: String) {
        guard requestID == request else { return }
        stop()
        state = .failed(message)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PhotosLibraryError.cloudOnly:
            "原始视频尚不在本机。浏览不会自动从 iCloud 下载；请先让原件在本机可用后重试。"
        case PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted:
            "无法读取 Photos 视频，请检查照片访问授权后重试。"
        case LibraryOriginalAssetOpenError.unsafeLocator:
            "视频位置无法安全访问，请重新连接来源后重试。"
        default:
            "无法播放此视频。请检查来源连接、读取授权和文件是否可用，然后重试。"
        }
    }
}

struct LibraryVideoViewer: View {
    let assetID: UUID
    let contentRevision: Int
    @ObservedObject var model: LibraryWorkspaceModel
    @ObservedObject private var session: LibraryVideoViewingSession
    @State private var reloadGeneration = 0

    init(assetID: UUID, contentRevision: Int, model: LibraryWorkspaceModel) {
        self.assetID = assetID
        self.contentRevision = contentRevision
        self.model = model
        session = model.videoViewingSession
    }

    private var identity: LibraryVideoViewingSession.Identity {
        .init(assetID: assetID, revision: contentRevision)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                switch session.state {
                case .ready where session.identity == identity:
                    LibraryVideoPlayerSurface(player: session.player)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("暂时无法播放视频", systemImage: "video.slash")
                    } description: { Text(message) }
                case .loading:
                    ProgressView("正在准备本机视频…")
                default:
                    ContentUnavailableView("视频已停止", systemImage: "pause.circle",
                                           description: Text("点击重新载入以继续观看。"))
                }
            }
            HStack {
                Picker("播放速度", selection: Binding(get: { session.speed }, set: { session.setSpeed($0) })) {
                    Text("0.5×").tag(Float(0.5))
                    Text("1×").tag(Float(1))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2))
                }
                .frame(width: 160)
                Spacer()
                Button("重新载入", systemImage: "arrow.clockwise") { reloadGeneration &+= 1 }
                Button("使用系统播放器打开", systemImage: "arrow.up.forward.app") {
                    session.stop()
                    Task { await model.openOriginalAssetInSystemPlayer(assetID: assetID) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("libraryVideoViewer")
        .task(id: "\(assetID):\(contentRevision):\(reloadGeneration)") {
            await session.load(identity: identity) {
                try await model.prepareVideoForViewing(assetID: assetID)
            }
        }
        .onDisappear { session.stop(ifMatching: identity) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.stop(ifMatching: identity)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadGeneration &+= 1
        }
    }
}

private struct LibraryVideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
