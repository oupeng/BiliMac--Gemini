import SwiftUI

struct VideoDetailView: View {
    let videoItem: VideoItem
    let onBack: () -> Void
    
    @StateObject private var playerManager = VideoPlayerManager()
    @State private var detail: VideoDetail?
    @State private var relatedVideos: [VideoItem] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航条
            HStack {
                Button(action: {
                    playerManager.cleanup()
                    onBack()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                
                Spacer()
                Text(detail?.title ?? videoItem.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: 500)
                Spacer()
            }
            .frame(height: 38)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // 详情主体左右分栏
            HSplitView {
                // 左侧：播放器 + 信息 + 画质选择 + 原生音量滑块 + 相关推荐
                VStack(spacing: 0) {
                    CustomPlayerView(playerManager: playerManager)
                        .aspectRatio(16/9, contentMode: .fit)
                        .background(Color.black)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(detail?.title ?? videoItem.title)
                                        .font(.title3.bold())
                                    
                                    HStack(spacing: 12) {
                                        Text(detail?.ownerName ?? videoItem.ownerName)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.secondary)
                                        Text("播放 \(detail?.viewCount ?? 0)  点赞 \(detail?.likeCount ?? 0)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                // 🌟 右上角控制组：原生音量调节滑块 + 清晰度切换
                                HStack(spacing: 12) {
                                    HStack(spacing: 4) {
                                        Image(systemName: playerManager.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Slider(value: $playerManager.volume, in: 0...1)
                                            .frame(width: 80)
                                            .accentColor(.pink)
                                    }
                                    
                                    if !playerManager.availableQualities.isEmpty {
                                        Picker("", selection: Binding(
                                            get: { playerManager.selectedQualityId },
                                            set: { playerManager.changeQuality(to: $0) }
                                        )) {
                                            ForEach(playerManager.availableQualities, id: \.id) { q in
                                                Text(q.name).tag(q.id)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 125)
                                    }
                                }
                            }
                            
                            Text(detail?.desc ?? "")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            
                            Divider().padding(.vertical, 4)
                            
                            Text("相关推荐")
                                .font(.headline)
                            
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                                ForEach(relatedVideos) { item in
                                    VideoCardView(item: item)
                                        .onTapGesture {
                                            switchVideo(item)
                                        }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .frame(minWidth: 550)
                
                // 右侧：只读评论区
                VStack(spacing: 0) {
                    HStack {
                        Text("评论区")
                            .font(.headline)
                        Spacer()
                        Text("只读")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    if let aid = detail?.aid {
                        CommentSectionView(aid: aid)
                    } else {
                        Spacer()
                    }
                }
                .frame(minWidth: 320, maxWidth: 420)
            }
        }
        .task {
            loadDetail(bvid: videoItem.bvid)
        }
        .onDisappear {
            playerManager.cleanup()
        }
    }
    
    private func loadDetail(bvid: String) {
        Task {
            if let d = try? await BiliService.shared.fetchVideoDetail(bvid: bvid) {
                self.detail = d
                playerManager.playVideo(bvid: d.bvid, cid: d.cid)
            }
            if let rel = try? await BiliService.shared.fetchRelatedVideos(bvid: bvid) {
                self.relatedVideos = rel
            }
        }
    }
    
    private func switchVideo(_ item: VideoItem) {
        playerManager.cleanup()
        loadDetail(bvid: item.bvid)
    }
}
