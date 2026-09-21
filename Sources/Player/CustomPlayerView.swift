import SwiftUI
import AVKit

// MARK: - 原生无控件视频渲染图层
struct PureVideoNSView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none // 完全关闭系统控件，交由纯正 SwiftUI 毛玻璃胶囊渲染
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}

// MARK: - 图 3 像素级同款：macOS 现代毛玻璃悬浮交互胶囊
struct CustomPlayerView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    
    @State private var isHovering: Bool = false
    @State private var isDraggingSlider: Bool = false
    @State private var dragTime: Double = 0
    @State private var hideTask: DispatchWorkItem?
    
    var body: some View {
        ZStack {
            // 底层：原生硬件加速视频渲染
            PureVideoNSView(player: playerManager.videoPlayer)
                .onTapGesture {
                    playerManager.togglePlay()
                    triggerHover()
                }
            
            // 顶层：图 3 所示的浮动毛玻璃控制胶囊
            if isHovering || !playerManager.isPlaying {
                VStack {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        // 🌟 上排控制区：音量滑块 + 播放/快进快退 + 画质菜单 + 全屏
                        HStack(spacing: 20) {
                            // 左侧：音量调节滑块 (图 3 样式)
                            HStack(spacing: 6) {
                                Button(action: {
                                    if playerManager.volume > 0 {
                                        playerManager.volume = 0
                                    } else {
                                        playerManager.volume = 0.8
                                    }
                                }) {
                                    Image(systemName: playerManager.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                                
                                Slider(value: $playerManager.volume, in: 0...1)
                                    .frame(width: 75)
                                    .accentColor(.white)
                            }
                            
                            Spacer()
                            
                            // 中间：快退 15s + 播放/暂停 + 快进 15s (图 3 样式)
                            HStack(spacing: 24) {
                                Button(action: { playerManager.seek(to: playerManager.currentTime - 15) }) {
                                    Image(systemName: "backward.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerManager.togglePlay() }) {
                                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 26))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { playerManager.seek(to: playerManager.currentTime + 15) }) {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            Spacer()
                            
                            // 右侧：全屏 + 真实清晰度切换菜单 (图 3 样式)
                            HStack(spacing: 14) {
                                // 全屏按钮
                                Button(action: {
                                    NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                                }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                .buttonStyle(.plain)
                                
                                // 画质切换下拉框 (标明当前真实物理分辨率)
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
                                            .font(.system(size: 11, weight: .bold))
                                        Image(systemName: "chevron.right.2")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(6)
                                }
                                .menuStyle(.borderlessButton)
                            }
                        }
                        
                        // 🌟 下排进度条区：当前时间 + 细线条进度条 + 总时长 (图 3 样式)
                        HStack(spacing: 12) {
                            Text(formatTime(isDraggingSlider ? dragTime : playerManager.currentTime))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                            
                            Slider(
                                value: Binding(
                                    get: { isDraggingSlider ? dragTime : playerManager.currentTime },
                                    set: { val in
                                        isDraggingSlider = true
                                        dragTime = val
                                    }
                                ),
                                in: 0...max(playerManager.duration, 1),
                                onEditingChanged: { editing in
                                    if !editing {
                                        playerManager.seek(to: dragTime)
                                        isDraggingSlider = false
                                    }
                                }
                            )
                            .accentColor(.white)
                            
                            Text(formatTime(playerManager.duration))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    // 🌟 纯正毛玻璃半透明材质 (图 3 质感)
                    .background(.ultraThinMaterial)
                    .background(Color.black.opacity(0.45))
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 15, x: 0, y: 5)
                    .frame(maxWidth: 580)
                    .padding(.bottom, 22)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onHover { hover in
            isHovering = hover
            if hover { triggerHover() }
        }
    }
    
    private func triggerHover() {
        isHovering = true
        hideTask?.cancel()
        let task = DispatchWorkItem {
            if playerManager.isPlaying && !isDraggingSlider {
                withAnimation { isHovering = false }
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }
    
    private func formatTime(_ sec: Double) -> String {
        guard !sec.isNaN && sec >= 0 else { return "00:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
