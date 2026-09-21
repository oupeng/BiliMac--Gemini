import SwiftUI
import AVKit

// MARK: - 接入 macOS 原生系统级毛玻璃悬浮播放器 (图 2 截图同款控件)
struct NativePlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 🌟 启用截图同款的 macOS 原生毛玻璃半透明浮动面板 (带音量滑块、AirPlay、进度条)
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.showsSharingServiceButton = false
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
