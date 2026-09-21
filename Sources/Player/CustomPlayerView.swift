import SwiftUI
import AVKit

// MARK: - 接入纯正 macOS 原生系统级毛玻璃播放器 (图 2 原生样式)
struct NativePlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFrameSteppingButtons = false
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}

struct CustomPlayerView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    
    var body: some View {
        NativePlayerViewRepresentable(player: playerManager.videoPlayer)
    }
}
