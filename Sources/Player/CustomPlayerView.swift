import SwiftUI
import AVKit

// MARK: - 纯正 macOS 原生浮动播放器 (图 3 BiliKit 同款控件)
struct NativePlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 🌟 启用图 3 所示的 macOS 原生半透明毛玻璃浮动交互胶囊
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
