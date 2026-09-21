import SwiftUI
import AVKit

// MARK: - 采用 Apple SwiftUI 原生第一方播放控件 (100% 对应截图样式)
struct CustomPlayerView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    
    var body: some View {
        // 🌟 直接调用 SwiftUI 官方 VideoPlayer，自带原生 ±15s 快进快退、全屏、画中画与时间进度条
        VideoPlayer(player: playerManager.videoPlayer)
            .background(Color.black)
    }
}
