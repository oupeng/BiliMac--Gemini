import SwiftUI
import AVKit

// MARK: - AppKit 纯原生播放器桥接 (彻底杜绝 _AVKit_SwiftUI 泛型元数据崩溃)
struct NativePlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        // 启用系统现代内置控件 (带进度条、全屏、画中画、快进快退)
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
        NativePlayerViewWrapper(player: playerManager.videoPlayer)
            .background(Color.black)
    }
}
