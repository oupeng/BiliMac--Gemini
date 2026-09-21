import SwiftUI
import AVKit

// MARK: - 现代 macOS 原生内嵌播放器控件 (Inline 风格)
struct NativePlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 🌟 启用 macOS 现代内嵌风格交互栏 (带原生现代进度条、音量控制、画中画与全屏)
        playerView.controlsStyle = .inline
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
