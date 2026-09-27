import AVKit
import ImageAllRemoteClient
import SwiftUI

struct RemoteVideoPreviewView: View {
    @ObservedObject var playback: RemoteVideoPlayback
    let message: String?
    let retry: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 10) {
            if let message {
                unavailable(message)
            } else {
                switch playback.state {
                case .ready:
                    VideoPlayer(player: playback.player)
                        .accessibilityLabel("视频播放，可调整进度和音量")
                case .loading:
                    ProgressView("正在准备视频…")
                case let .failed(message):
                    unavailable(message)
                case .idle:
                    unavailable("视频已停止，点击重试以继续观看。")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.stop() }
        }
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.bordered)
        }
        .padding()
    }
}
