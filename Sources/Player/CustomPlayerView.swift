import SwiftUI
import AVKit

// MARK: - 接入 macOS 原生原生系统级播放器 (图 2 样式)
struct NativePlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        
        // 🌟 启用图 2 同款的 macOS 系统原生毛玻璃浮动控制栏
        playerView.controlsStyle = .floating
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServicePicker = false
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
        ZStack(alignment: .topTrailing) {
            // 原生播放视图 (内置原生进度条、原生音量滑块、原生暂停播放和快进)
            NativePlayerViewRepresentable(player: playerManager.videoPlayer)
            
            // 右上角浮层：当前清晰度与切换菜单
            if !playerManager.availableQualities.isEmpty {
                Menu {
                    ForEach(playerManager.availableQualities, id: \.id) { q in
                        Button(action: {
                            playerManager.changeQuality(to: q.id)
                        }) {
                            HStack {
                                Text(q.name)
                                if q.id == playerManager.selectedQualityId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(playerManager.currentQualityName)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                    .shadow(radius: 2)
                }
                .menuStyle(.borderlessButton)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
    }
}
