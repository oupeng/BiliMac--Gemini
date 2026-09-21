import SwiftUI
import AVKit

struct AVPlayerNSViewWrapper: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none // 自绘 SwiftUI 控制栏
        view.videoGravity = .resizeAspect
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}

struct CustomPlayerView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            AVPlayerNSViewWrapper(player: playerManager.videoPlayer)
                .onTapGesture {
                    playerManager.togglePlay()
                }
            
            // 悬浮自制控制栏
            VStack {
                Spacer()
                if isHovering || !playerManager.isPlaying {
                    VStack(spacing: 8) {
                        // 进度条
                        Slider(
                            value: Binding(
                                get: { playerManager.currentTime },
                                set: { playerManager.seek(to: $0) }
                            ),
                            in: 0...max(playerManager.duration, 1)
                        )
                        .accentColor(.pink)
                        
                        HStack(spacing: 12) {
                            Button(action: { playerManager.togglePlay() }) {
                                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                            
                            Text("\(formatTime(playerManager.currentTime)) / \(formatTime(playerManager.duration))")
                                .font(.caption.monospacedDigit())
                            
                            Spacer()
                            
                            // 清晰度切换下拉菜单
                            Menu {
                                ForEach(playerManager.availableQualities, id: \.id) { q in
                                    Button(action: { playerManager.changeQuality(to: q.id) }) {
                                        HStack {
                                            Text(q.name)
                                            if q.id == playerManager.selectedQualityId {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(playerManager.currentQualityName)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.3))
                                    .cornerRadius(6)
                            }
                            .menuStyle(.borderlessButton)
                            
                            // 音量调节 (自动记住)
                            HStack(spacing: 4) {
                                Image(systemName: playerManager.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                Slider(value: $playerManager.volume, in: 0...1)
                                    .frame(width: 70)
                                    .accentColor(.pink)
                            }
                            
                            // 全屏切换
                            Button(action: {
                                NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                            }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75))
                    .transition(.opacity)
                }
            }
        }
        .onHover { isHovering = $0 }
    }
    
    private func formatTime(_ sec: Double) -> String {
        guard !sec.isNaN && sec >= 0 else { return "00:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
