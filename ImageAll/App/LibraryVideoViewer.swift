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
    @Published private(set) var technicalMetadata: VideoTechnicalMetadata?
    @Published private(set) var technicalMetadataLoadFinished = false
    private(set) var identity: Identity?
    @Published private(set) var canRequestCloudDownload = false
    @Published private(set) var cloudDownloadProgress: Double?
    private var cloudRequestID: UUID?
    private var preparationTask: Task<LibraryVideoPlaybackResource, Error>?
    private var requestID: UUID?
    private var resource: LibraryVideoPlaybackResource?
    private var itemObservation: NSKeyValueObservation?

    func load(
        identity: Identity,
        cloudDownloadRequestID: UUID? = nil,
        onTechnicalMetadata: (@MainActor (VideoTechnicalMetadata) async -> Void)? = nil,
        prepare: @escaping @MainActor () async throws -> LibraryVideoPlaybackResource
    ) async {
        stop()
        let request = UUID()
        requestID = request
        self.identity = identity
        state = .loading
        cloudRequestID = cloudDownloadRequestID
        cloudDownloadProgress = cloudDownloadRequestID == nil ? nil : 0
        do {
            let task = Task { @MainActor in try await prepare() }
            preparationTask = task
            let prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            if requestID == request { preparationTask = nil }
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
            cloudDownloadProgress = nil
            cloudRequestID = nil
            state = .ready
            // Playback is usable immediately; optional metadata failure must not fail the player.
            let observed = try? await Self.readTechnicalMetadata(asset)
            guard requestID == request else { return }
            guard !Task.isCancelled else { stop(); return }
            technicalMetadata = observed
            technicalMetadataLoadFinished = true
            if let observed { await onTechnicalMetadata?(observed) }
        } catch {
            guard requestID == request else { return }
            if Task.isCancelled || error is CancellationError {
                stop()
            } else {
                fail(request: request, message: Self.message(for: error))
                canRequestCloudDownload = error as? PhotosLibraryError == .cloudOnly
                    || (cloudDownloadRequestID != nil
                        && error as? PhotosVideoResourceError != .unsupportedAssetRepresentation
                        && error as? PhotosLibraryError != .authorizationDenied
                        && error as? PhotosLibraryError != .authorizationRestricted)

            }
        }
    }

    func reportCloudProgress(_ value: Double, request: UUID) {
        guard cloudRequestID == request, state == .loading, value.isFinite else { return }
        cloudDownloadProgress = max(cloudDownloadProgress ?? 0, min(max(value, 0), 1))
    }

    func togglePlayback() {
        guard state == .ready else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func seekToAnalysisTime(_ milliseconds: Int64, expected: Identity) async -> Bool {
        guard identity == expected, state == .ready, milliseconds >= 0,
              let item = player.currentItem else { return false }
        let duration = try? await item.asset.load(.duration)
        guard identity == expected, state == .ready,
              let duration, duration.isNumeric, Double(milliseconds) / 1_000 < duration.seconds else { return false }
        player.pause()
        let completed = await player.seek(to: CMTime(value: milliseconds, timescale: 1_000),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
        return completed && identity == expected && state == .ready
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
        preparationTask?.cancel()
        preparationTask = nil
        cloudRequestID = nil
        cloudDownloadProgress = nil
        canRequestCloudDownload = false
        identity = nil
        technicalMetadata = nil
        technicalMetadataLoadFinished = false
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

    private static func readTechnicalMetadata(_ asset: AVAsset) async throws -> VideoTechnicalMetadata? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (formats, frameRate, dataRate) = try await track.load(
            .formatDescriptions, .nominalFrameRate, .estimatedDataRate
        )
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let codec = formats.first.flatMap { format -> String? in
            let code = CMFormatDescriptionGetMediaSubType(format)
            return String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                                  UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii)
        }
        return VideoTechnicalMetadata(
            codec: codec,
            nominalFrameRate: frameRate.isFinite && frameRate > 0 ? Double(frameRate) : nil,
            estimatedDataRate: dataRate.isFinite && dataRate > 0 ? Double(dataRate) : nil,
            audioTrackCount: audio.count
        )
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PhotosLibraryError.cloudOnly:
            "原始视频尚不在本机。浏览不会自动从 iCloud 下载；可明确获取当前视频，或先在“照片”中下载后重试。"
        case PhotosVideoResourceError.unsupportedAssetRepresentation:
            "Photos 返回了编辑合成资源，当前播放器仅支持本地文件原件。请在“照片”中播放，或导出视频文件后接入文件夹。"
        case PhotosVideoResourceError.insufficientSpace:
            "Photos 无法取得原件：本机可用空间不足。请释放空间后再次明确获取；已下载的 Photos 缓存由系统管理。"
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
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisRequest: UUID?
    @State private var analysisFrames: [VideoAnalysisFrame] = []
    @State private var analysisMessage: String?
    @State private var reloadGeneration = 0
    @State private var showsTechnicalInformation = false
    @State private var confirmsCloudDownload = false
    @State private var cloudConfirmationIdentity: LibraryVideoViewingSession.Identity?
    @State private var pendingCloudDownload: (identity: LibraryVideoViewingSession.Identity, request: UUID, grant: PhotosCloudDownloadGrant)?

    init(assetID: UUID, contentRevision: Int, model: LibraryWorkspaceModel) {
        self.assetID = assetID
        self.contentRevision = contentRevision
        self.model = model
        session = model.videoViewingSession
    }

    private var identity: LibraryVideoViewingSession.Identity {
        .init(assetID: assetID, revision: contentRevision)
    }

    private func recordTechnicalMetadata(_ metadata: VideoTechnicalMetadata) async {
        await model.recordVideoTechnicalMetadataForViewing(
            assetID: assetID, expectedRevision: contentRevision, metadata: metadata
        )
    }

    private func cancelAnalysis() {
        analysisRequest = nil
        analysisTask?.cancel()
        analysisTask = nil
    }

    private func analyzeVideo(forceRebuild: Bool = false) {
        guard let service = model.videoAnalysisService else { return }
        cancelAnalysis()
        analysisFrames = []
        analysisMessage = nil
        let request = UUID()
        let selected = identity
        analysisRequest = request
        analysisTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                let sampling = try service.analyze(assetID: selected.assetID, expectedRevision: selected.revision,
                    forceRebuild: forceRebuild,
                    checkCancellation: { try Task.checkCancellation() })
                let features = try VideoMultiFrameFeatureSet.generate(sampling,
                    checkCancellation: { try Task.checkCancellation() })
                return (sampling, features.aggregate.count)
            }
            do {
                let (sampling, dimensions) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, analysisRequest == request, identity == selected else { return }
                analysisFrames = sampling.frames
                analysisMessage = "分析 \(sampling.frames.count) 帧 · 复用 \(sampling.reusedFrameCount) 帧 · \(dimensions) 维特征。点击时间点定位播放。"
            } catch {
                guard analysisRequest == request, !Task.isCancelled else { return }
                analysisMessage = "无法完成多帧分析。当前入口支持可读取的本地文件夹视频；请检查来源、时长及内容是否发生变化。"
            }
            if analysisRequest == request { analysisTask = nil; analysisRequest = nil }
        }
    }

    private var analysisEvidence: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    Button("分析当前视频（复用有效帧）") { analyzeVideo() }
                    Button("强制重建当前视频分析帧") { analyzeVideo(forceRebuild: true) }
                } label: { Label("多帧分析", systemImage: "film.stack") }
                    .disabled(model.videoAnalysisService == nil || analysisTask != nil || session.state != .ready
                        || model.inspectorDetail?.assetID != assetID || model.inspectorDetail?.relativePath == nil
                        || (model.inspectorDetail?.durationMs ?? 0) <= 0)
                    .help("仅处理当前视频。强制重建会重新解码，旧封面和精确去重证据保持不变。")
                if analysisTask != nil {
                    ProgressView().controlSize(.small)
                    Button("取消分析") { cancelAnalysis(); analysisMessage = "已取消，可再次分析以复用有效检查点。" }
                }
                Text("文件夹视频 · 最多 5 帧 · 仅主动分析").font(.caption).foregroundStyle(.secondary)
            }
            if let analysisMessage { Text(analysisMessage).font(.caption).foregroundStyle(.secondary) }
            if !analysisFrames.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(analysisFrames, id: \.actualTimeMs) { frame in
                            Button {
                                Task { @MainActor in
                                    if !(await session.seekToAnalysisTime(frame.actualTimeMs, expected: identity)) {
                                        analysisMessage = "当前视频无法定位，请重新载入后再试。"
                                    }
                                }
                            } label: {
                                VStack {
                                    if let image = NSImage(data: frame.jpegBytes) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 60)
                                    }
                                    Text(String(format: "%.3f 秒", Double(frame.actualTimeMs) / 1_000)).font(.caption.monospacedDigit())
                                }
                            }.buttonStyle(.bordered)
                        }
                    }
                }.frame(height: 94)
            }
        }.padding(.horizontal, 12).padding(.bottom, 8)
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
                    } description: { Text(message) } actions: {
                        if session.canRequestCloudDownload {
                            Button("从 iCloud 获取当前视频") {
                                cloudConfirmationIdentity = identity
                                confirmsCloudDownload = true
                            }
                        }
                    }
                case .loading:
                    if let progress = session.cloudDownloadProgress {
                        VStack {
                            ProgressView("正在从 iCloud 获取当前视频…", value: progress, total: 1)
                            Button("取消获取") { session.stop(ifMatching: identity) }
                        }.padding()
                    } else {
                        ProgressView("正在准备本机视频…")
                    }
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
                Button("视频信息", systemImage: "info.circle") { showsTechnicalInformation.toggle() }
                    .disabled(session.identity != identity || session.state != .ready)
                    .popover(isPresented: $showsTechnicalInformation) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("本地播放资源信息").font(.headline)
                            if !session.technicalMetadataLoadFinished {
                                ProgressView("正在读取技术信息…")
                            } else if session.technicalMetadata == nil {
                                Text("无法读取此资源的技术信息，仍可继续播放或重新载入。")
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("编码", value: session.technicalMetadata?.codec ?? "未知")
                            LabeledContent("标称帧率", value: session.technicalMetadata?.nominalFrameRate.map {
                                String(format: "%.2f fps", $0)
                            } ?? "未知")
                            LabeledContent("估算码率", value: session.technicalMetadata?.estimatedDataRate.map {
                                String(format: "%.0f kb/s", $0 / 1000)
                            } ?? "未知")
                            LabeledContent("音轨", value: session.technicalMetadata?.audioTrackCount.map {
                                $0 == 0 ? "未发现音轨" : "\($0) 条"
                            } ?? "未知")
                            Text("标称帧率不保证恒定帧率；音轨数量不表示已分析音频内容。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding().frame(width: 320)
                    }
                Button("重新载入", systemImage: "arrow.clockwise") { reloadGeneration &+= 1 }
                Button("使用系统播放器打开", systemImage: "arrow.up.forward.app") {
                    session.stop()
                    Task { await model.openOriginalAssetInSystemPlayer(assetID: assetID) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            analysisEvidence
        }
        .accessibilityIdentifier("libraryVideoViewer")
        .task(id: "\(assetID):\(contentRevision):\(reloadGeneration)") {
            let download = pendingCloudDownload
            pendingCloudDownload = nil
            if let download, download.identity == identity {
                await session.load(identity: identity, cloudDownloadRequestID: download.request,
                                   onTechnicalMetadata: recordTechnicalMetadata) {
                    try await model.downloadCloudVideoForViewing(
                        assetID: assetID, expectedRevision: contentRevision, grant: download.grant
                    ) { progress in
                        Task { @MainActor in session.reportCloudProgress(progress, request: download.request) }
                    }
                }
            } else {
                await session.load(identity: identity, onTechnicalMetadata: recordTechnicalMetadata) {
                    try await model.prepareVideoForViewing(assetID: assetID)
                }
            }
        }
        .confirmationDialog("从 iCloud 获取当前视频原件？", isPresented: $confirmsCloudDownload) {
            Button("获取当前视频") {
                guard cloudConfirmationIdentity == identity, session.canRequestCloudDownload else { return }
                pendingCloudDownload = (identity, UUID(), .issue())
                reloadGeneration &+= 1
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将使用网络获取此视频原件，可能消耗流量与本机空间。最多处理一个当前视频，不会批量下载；空间不足时会停止并提示。你可以取消等待。Photos 已接收的本地缓存由系统管理。")
        }
        .onChange(of: identity) { _, _ in
            cancelAnalysis(); analysisFrames = []; analysisMessage = nil
        }
        .onDisappear { cancelAnalysis(); session.stop(ifMatching: identity) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelAnalysis()
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
