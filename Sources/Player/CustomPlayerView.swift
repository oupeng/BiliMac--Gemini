import SwiftUI
import AVKit

// MARK: - 接入 macOS 纯原生浮动播放器 (合成流后音量滑块、画中画全量现身)
struct NativePlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 启用 macOS 原生半透明浮动面板 (单流合成成功后，音量条与画中画会自动浮现)
        playerView.controlsStyle = .floating
        playerView.allowsPictureInPicturePlayback = true
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
