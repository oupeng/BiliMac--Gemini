import SwiftUI
import AVKit

// MARK: - 接入现代 macOS 原生播放控件 (你截图中的原生控件样式)
struct NativePlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 🌟 启用 macOS 现代系统级原生控制栏（带 15s 进退、原生进度条、全屏、画中画）
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.showsFrameSteppingButtons = false
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
